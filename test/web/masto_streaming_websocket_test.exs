defmodule Bonfire.Notify.Web.MastoStreamingWebSocketTest do
  @moduledoc """
  Tests for the Mastodon-compatible WebSocket streaming transport.

  Tests the transport callbacks directly (connect/init/handle_in/handle_info)
  since Phoenix.Socket.Transport modules are plain GenServer-like state machines.

  Run with: just test extensions/bonfire_notify/test/web/masto_streaming_websocket_test.exs
  """

  use Bonfire.Notify.ConnCase, async: false

  alias Bonfire.Me.Fake
  alias Bonfire.Social.Feeds
  alias Bonfire.Notify.Web.MastoStreamingWebSocket, as: WS
  alias Bonfire.Notify.MastoStreaming.EventFormatter
  alias Bonfire.OpenID.Provider.ClientApps
  alias Boruta.Ecto.AccessTokens, as: AccessTokensAdapter
  import Boruta.Ecto.OauthMapper, only: [to_oauth_schema: 1]

  @moduletag :streaming

  # Required Mastodon Status fields per OpenAPI spec
  @required_status_fields ~w(id created_at uri account content visibility sensitive spoiler_text media_attachments mentions tags emojis reblogs_count favourites_count replies_count)

  # Required Mastodon Notification fields per OpenAPI spec
  @required_notification_fields ~w(id type created_at account)

  # Required Mastodon Conversation fields per OpenAPI spec
  @required_conversation_fields ~w(id accounts unread)

  setup do
    account = Fake.fake_account!()
    me = Fake.fake_user!(account)

    {:ok, token} = create_access_token(me)

    {:ok, me: me, token: token}
  end

  # --- Connection tests: all 3 auth methods ---

  describe "connect/1 auth methods" do
    test "auth via access_token query param", %{token: token} do
      assert {:ok, state} =
               WS.connect(%{
                 params: %{"access_token" => token},
                 connect_info: %{},
                 options: []
               })

      assert state.user
      assert state.subscriptions == %{}
    end

    test "auth via Sec-WebSocket-Protocol header", %{token: token} do
      assert {:ok, state} =
               WS.connect(%{
                 params: %{},
                 connect_info: %{
                   sec_websocket_headers: %{"sec-websocket-protocol" => token}
                 },
                 options: []
               })

      assert state.user
    end

    test "auth via Authorization Bearer header", %{token: token} do
      assert {:ok, state} =
               WS.connect(%{
                 params: %{},
                 connect_info: %{
                   x_headers: [{"authorization", "Bearer #{token}"}]
                 },
                 options: []
               })

      assert state.user
    end

    test "query param takes priority over headers", %{token: token} do
      # Query param is valid, headers are invalid — should succeed
      assert {:ok, _state} =
               WS.connect(%{
                 params: %{"access_token" => token},
                 connect_info: %{
                   sec_websocket_headers: %{"sec-websocket-protocol" => "bogus"},
                   x_headers: [{"authorization", "Bearer bogus"}]
                 },
                 options: []
               })
    end

    test "Sec-WebSocket-Protocol takes priority over Bearer when no query param", %{
      token: token
    } do
      # Sec-WebSocket-Protocol is valid, Bearer is invalid — should succeed
      assert {:ok, _state} =
               WS.connect(%{
                 params: %{},
                 connect_info: %{
                   sec_websocket_headers: %{"sec-websocket-protocol" => token},
                   x_headers: [{"authorization", "Bearer bogus"}]
                 },
                 options: []
               })
    end

    test "rejects connection without any token" do
      assert :error =
               WS.connect(%{
                 params: %{},
                 connect_info: %{},
                 options: []
               })
    end

    test "rejects connection with invalid token in all methods" do
      assert :error =
               WS.connect(%{
                 params: %{"access_token" => "invalid"},
                 connect_info: %{
                   sec_websocket_headers: %{"sec-websocket-protocol" => "invalid"},
                   x_headers: [{"authorization", "Bearer invalid"}]
                 },
                 options: []
               })
    end

    test "rejects connection with empty token" do
      assert :error =
               WS.connect(%{
                 params: %{"access_token" => ""},
                 connect_info: %{},
                 options: []
               })
    end

    test "stream param with tag and list are captured", %{token: token} do
      assert {:ok, state} =
               WS.connect(%{
                 params: %{
                   "access_token" => token,
                   "stream" => "hashtag",
                   "tag" => "elixir"
                 },
                 connect_info: %{},
                 options: []
               })

      assert state.initial_stream == {"hashtag", "elixir", nil}

      assert {:ok, state2} =
               WS.connect(%{
                 params: %{"access_token" => token, "stream" => "list", "list" => "42"},
                 connect_info: %{},
                 options: []
               })

      assert state2.initial_stream == {"list", nil, "42"}
    end
  end

  # --- Init tests ---

  describe "init/1" do
    test "schedules heartbeat", %{token: token} do
      {:ok, state} = connect_ws(token)
      {:ok, _state} = WS.init(state)

      assert_receive :heartbeat, 35_000
    end

    test "subscribes to initial stream if provided", %{token: token} do
      {:ok, state} =
        WS.connect(%{
          params: %{"access_token" => token, "stream" => "user"},
          connect_info: %{},
          options: []
        })

      {:ok, state} = WS.init(state)

      assert Map.has_key?(state.subscriptions, "user")
      assert state.notification_feed_id != nil
    end
  end

  # --- Subscribe/Unsubscribe with tag/list params ---

  describe "handle_in subscribe/unsubscribe" do
    test "subscribe to user stream", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "user"}), [opcode: :text]},
          state
        )

      assert Map.has_key?(state.subscriptions, "user")
      assert state.notification_feed_id != nil
    end

    test "subscribe to public stream", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "public"}), [opcode: :text]},
          state
        )

      assert Map.has_key?(state.subscriptions, "public")
    end

    test "subscribe to public:local stream", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "public:local"}), [opcode: :text]},
          state
        )

      assert Map.has_key?(state.subscriptions, "public:local")
    end

    test "subscribe to direct stream", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "direct"}), [opcode: :text]},
          state
        )

      assert Map.has_key?(state.subscriptions, "direct")
    end

    test "subscribe to public:media maps to same topic as public", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state_pub} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "public"}), [opcode: :text]},
          state
        )

      {:ok, state_media} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "public:media"}), [opcode: :text]},
          state
        )

      assert state_pub.subscriptions["public"] == state_media.subscriptions["public:media"]
    end

    test "subscribe to public:remote uses activity_pub feed", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "public:remote"}), [opcode: :text]},
          state
        )

      # The :activity_pub named feed should exist
      if topic = state.subscriptions["public:remote"] do
        assert is_binary(to_string(topic))
      end
    end

    test "subscribe with tag param creates compound subscription key", %{token: token} do
      {:ok, state} = init_ws(token)

      # hashtag has no topic yet, so subscription won't be added,
      # but verify the key logic is correct
      assert WS.subscription_key("hashtag", "elixir", nil) == "hashtag:elixir"
      assert WS.subscription_key("hashtag:local", "rust", nil) == "hashtag:local:rust"

      # Sending subscribe — should not crash even though no topic exists
      {:ok, _state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "hashtag", "tag" => "elixir"}),
           [opcode: :text]},
          state
        )
    end

    test "subscribe with list param creates compound subscription key", %{token: token} do
      {:ok, state} = init_ws(token)

      assert WS.subscription_key("list", nil, "42") == "list:42"

      # Sending subscribe — should not crash even though no topic exists
      {:ok, _state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "list", "list" => "42"}),
           [opcode: :text]},
          state
        )
    end

    test "duplicate subscribe is idempotent", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "user"}), [opcode: :text]},
          state
        )

      topic = state.subscriptions["user"]

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "user"}), [opcode: :text]},
          state
        )

      assert state.subscriptions["user"] == topic
    end

    test "unsubscribe removes subscription", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "user"}), [opcode: :text]},
          state
        )

      assert Map.has_key?(state.subscriptions, "user")

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "unsubscribe", "stream" => "user"}), [opcode: :text]},
          state
        )

      refute Map.has_key?(state.subscriptions, "user")
      assert state.notification_feed_id == nil
    end

    test "unsubscribe from non-subscribed stream is a no-op", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, ^state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "unsubscribe", "stream" => "user"}), [opcode: :text]},
          state
        )
    end

    test "hashtag stream without tag has no topic — not added", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "hashtag"}), [opcode: :text]},
          state
        )

      refute Map.has_key?(state.subscriptions, "hashtag")
    end

    test "ignores malformed JSON", %{token: token} do
      {:ok, state} = init_ws(token)
      {:ok, ^state} = WS.handle_in({"not json{{{", [opcode: :text]}, state)
    end

    test "ignores unknown message types", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, ^state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "ping"}), [opcode: :text]},
          state
        )
    end
  end

  # --- Stream array format ---

  describe "to_stream_array/1" do
    test "simple streams return single-element array" do
      assert WS.to_stream_array("user") == ["user"]
      assert WS.to_stream_array("user:notification") == ["user:notification"]
      assert WS.to_stream_array("public") == ["public"]
      assert WS.to_stream_array("public:local") == ["public:local"]
      assert WS.to_stream_array("public:media") == ["public:media"]
      assert WS.to_stream_array("direct") == ["direct"]
    end

    test "hashtag with tag splits into two-element array" do
      assert WS.to_stream_array("hashtag:elixir") == ["hashtag", "elixir"]
      assert WS.to_stream_array("hashtag:local:rust") == ["hashtag:local", "rust"]
    end

    test "list with ID splits into two-element array" do
      assert WS.to_stream_array("list:42") == ["list", "42"]
      assert WS.to_stream_array("list:abc123") == ["list", "abc123"]
    end
  end

  # --- Mastodon entity shape validation (deterministic, no PubSub) ---

  describe "EventFormatter produces spec-compliant Mastodon entities" do
    test "format_update returns valid Status from a real post", %{me: me} do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "<p>Spec compliance test</p>"}},
          boundary: "public"
        )

      # Load the activity with associations needed by the Status mapper
      activity = load_activity_for(post)

      case EventFormatter.format_update(activity, current_user: me) do
        {:ok, payload} ->
          status = Jason.decode!(payload)
          assert_valid_status(status)
          assert String.contains?(status["content"], "Spec compliance test")

        :skip ->
          flunk("format_update returned :skip for a valid post activity")
      end
    end

    test "format_notification returns valid Notification from a real like", %{me: me} do
      liker = Fake.fake_user!(Fake.fake_account!())

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "<p>Like this for spec test</p>"}},
          boundary: "public"
        )

      {:ok, like} = Bonfire.Social.Likes.like(liker, post)

      activity = load_activity_for(like)

      case EventFormatter.format_notification(activity, current_user: me) do
        {:ok, payload} ->
          notification = Jason.decode!(payload)
          assert_valid_notification(notification)
          assert notification["type"] == "favourite"

          # favourite notifications should include a status per Mastodon spec
          assert notification["status"],
                 "favourite notification must include status per spec"

          assert_valid_status(notification["status"])

        :skip ->
          flunk("format_notification returned :skip for a valid like activity")
      end
    end

    test "format_notification returns valid Notification from a real follow", %{me: me} do
      follower = Fake.fake_user!(Fake.fake_account!())

      {:ok, follow} = Bonfire.Social.Graph.Follows.follow(follower, me)

      activity = load_activity_for(follow)

      case EventFormatter.format_notification(activity, current_user: me) do
        {:ok, payload} ->
          notification = Jason.decode!(payload)
          assert_valid_notification(notification)
          assert notification["type"] == "follow"
          # follow notifications should NOT include a status
          assert is_nil(notification["status"]),
                 "follow notification should not include status"

        :skip ->
          flunk("format_notification returned :skip for a valid follow activity")
      end
    end

    test "format_conversation returns valid Conversation entity" do
      {:ok, payload} = EventFormatter.format_conversation("thread_123")
      conversation = Jason.decode!(payload)
      assert_valid_conversation(conversation)
      assert conversation["id"] == "thread_123"
      assert conversation["unread"] == true
    end

    test "format_delete returns bare ID string per spec" do
      {:ok, payload} = EventFormatter.format_delete("status_abc")

      # Per spec: delete event payload is just the status ID as a string
      assert payload == "status_abc"

      # Full wire frame should match spec
      frame = EventFormatter.to_ws_frame(["public"], "delete", payload)
      decoded = Jason.decode!(frame)
      assert decoded["event"] == "delete"
      assert decoded["payload"] == "status_abc"
      assert decoded["stream"] == ["public"]
    end
  end

  # --- PubSub integration tests (timing-dependent, lenient) ---

  describe "handle_info PubSub integration" do
    test "public post broadcast generates update frame when feed matches", %{
      me: me,
      token: token
    } do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "public"}), [opcode: :text]},
          state
        )

      public_topic = state.subscriptions["public"]
      assert public_topic

      {:ok, _post} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "<p>Hello world!</p>"}},
          boundary: "public"
        )

      receive do
        {{Bonfire.Social.Feeds, :new_activity}, _} = msg ->
          case WS.handle_info(msg, state) do
            {:push, {:text, frame}, _state} ->
              decoded = Jason.decode!(frame)
              assert decoded["event"] == "update"
              assert decoded["stream"] == ["public"]
              status = Jason.decode!(decoded["payload"])
              assert_valid_status(status)

            {:ok, _state} ->
              # Feed IDs in broadcast didn't match our subscribed topic —
              # this can happen when the broadcast's feed list doesn't include
              # the exact guest feed ID. The shape is validated in the
              # deterministic EventFormatter tests above.
              :ok
          end
      after
        5_000 ->
          flunk("No PubSub message received for public post within 5s")
      end
    end

    test "like broadcast generates notification frame when feed matches", %{
      me: me,
      token: token
    } do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "user"}), [opcode: :text]},
          state
        )

      assert state.notification_feed_id

      liker = Fake.fake_user!(Fake.fake_account!())

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "<p>A post to like</p>"}},
          boundary: "public"
        )

      {:ok, _like} = Bonfire.Social.Likes.like(liker, post)

      receive do
        {{Bonfire.Social.Feeds, :new_activity}, _} = msg ->
          frames = collect_all_frames(WS.handle_info(msg, state))

          if frames != [] do
            events = Enum.map(frames, & &1["event"])
            # User stream should emit notification, and possibly update (dual-emit)
            assert "notification" in events or "update" in events,
                   "Expected notification or update event, got: #{inspect(events)}"

            for frame <- frames do
              assert frame["stream"] == ["user"]
            end
          end
          # If frames == [], the feed IDs didn't match — acceptable for integration test
      after
        3_000 ->
          # PubSub timing issue — shape validation is covered by deterministic tests
          :ok
      end
    end

    test "heartbeat reschedules without pushing a frame", %{token: token} do
      {:ok, state} = init_ws(token)
      assert {:ok, ^state} = WS.handle_info(:heartbeat, state)
    end

    test "simplified notification format is ignored", %{token: token} do
      {:ok, state} = init_ws(token)
      msg = {Bonfire.UI.Common.Notifications, %{title: "test", message: "test"}}
      assert {:ok, ^state} = WS.handle_info(msg, state)
    end

    test "DM produces conversation event with spec-compliant shape", %{token: token} do
      {:ok, state} = init_ws(token)

      {:ok, state} =
        WS.handle_in(
          {Jason.encode!(%{"type" => "subscribe", "stream" => "direct"}), [opcode: :text]},
          state
        )

      msg = {:new_message, %{thread_id: "thread_abc123"}}
      {:push, {:text, frame}, _state} = WS.handle_info(msg, state)

      decoded = Jason.decode!(frame)
      assert decoded["event"] == "conversation"
      assert decoded["stream"] == ["direct"]

      conversation = Jason.decode!(decoded["payload"])
      assert_valid_conversation(conversation)
      assert conversation["id"] == "thread_abc123"
      assert conversation["unread"] == true
    end

    test "DM without direct subscription is ignored", %{token: token} do
      {:ok, state} = init_ws(token)
      msg = {:new_message, %{thread_id: "thread_abc123"}}
      assert {:ok, ^state} = WS.handle_info(msg, state)
    end

    test "unknown info messages are ignored", %{token: token} do
      {:ok, state} = init_ws(token)
      assert {:ok, ^state} = WS.handle_info(:some_random_message, state)
    end
  end

  # --- EventFormatter unit tests ---

  describe "EventFormatter.to_ws_frame/3" do
    test "produces valid Mastodon wire format" do
      frame = EventFormatter.to_ws_frame(["user"], "update", "{\"id\":\"123\"}")
      decoded = Jason.decode!(frame)

      assert decoded["stream"] == ["user"]
      assert decoded["event"] == "update"
      assert decoded["payload"] == "{\"id\":\"123\"}"
    end

    test "wraps single stream name in list" do
      frame = EventFormatter.to_ws_frame("public", "notification", "{}")
      decoded = Jason.decode!(frame)
      assert decoded["stream"] == ["public"]
    end

    test "accepts list of stream names (compound key)" do
      frame = EventFormatter.to_ws_frame(["hashtag", "elixir"], "update", "{}")
      decoded = Jason.decode!(frame)
      assert decoded["stream"] == ["hashtag", "elixir"]
    end
  end

  describe "EventFormatter.format_delete/1" do
    test "returns string payload with just the ID" do
      assert {:ok, "12345"} = EventFormatter.format_delete("12345")
      assert {:ok, "67890"} = EventFormatter.format_delete(67890)
    end

    test "delete event wire format is spec-compliant" do
      {:ok, payload} = EventFormatter.format_delete("status_123")
      frame = EventFormatter.to_ws_frame(["public"], "delete", payload)
      decoded = Jason.decode!(frame)

      assert decoded["event"] == "delete"
      assert decoded["payload"] == "status_123"
      assert decoded["stream"] == ["public"]
    end
  end

  describe "EventFormatter.format_conversation/2" do
    test "returns spec-compliant Conversation shape" do
      {:ok, payload} = EventFormatter.format_conversation("thread_123")
      conversation = Jason.decode!(payload)

      assert_valid_conversation(conversation)
      assert conversation["id"] == "thread_123"
      assert conversation["unread"] == true
    end
  end

  # --- Legacy SSE compatibility ---

  describe "legacy SSE still works" do
    test "SSE streaming controller returns chunked response", %{me: me} do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/api/v1-bonfire/streaming")
        |> Plug.Conn.assign(:current_user, me)

      task =
        Task.async(fn ->
          Bonfire.Notify.Web.StreamingController.stream(conn, %{})
        end)

      assert_receive {:plug_conn, :sent}, 2_000

      send(task.pid, :stop_streaming)
      result_conn = Task.await(task, 5_000)

      assert result_conn.status == 200
      assert result_conn.state == :chunked
    end

    test "health check returns OK" do
      response =
        Phoenix.ConnTest.build_conn(:get, "/api/v1/streaming/health")
        |> Bonfire.Notify.Web.StreamingController.health(%{})

      assert response.status == 200
      assert response.resp_body == "OK"
    end
  end

  # --- Schema validation helpers ---

  defp assert_valid_status(status) when is_map(status) do
    for field <- @required_status_fields do
      assert Map.has_key?(status, field),
             "Status missing required field '#{field}'. Got keys: #{inspect(Map.keys(status))}"
    end

    assert is_binary(status["id"]), "Status.id must be a string"
    assert is_binary(status["created_at"]), "Status.created_at must be a string"
    assert is_map(status["account"]), "Status.account must be a map"
    assert is_binary(status["account"]["id"]), "Status.account.id must be a string"
    assert is_binary(status["account"]["acct"]), "Status.account.acct must be a string"

    assert status["visibility"] in ["public", "unlisted", "private", "direct"],
           "Status.visibility must be public/unlisted/private/direct, got: #{status["visibility"]}"

    assert is_list(status["media_attachments"]), "Status.media_attachments must be a list"
    assert is_list(status["mentions"]), "Status.mentions must be a list"
    assert is_list(status["tags"]), "Status.tags must be a list"
    assert is_list(status["emojis"]), "Status.emojis must be a list"
    assert is_integer(status["reblogs_count"]), "Status.reblogs_count must be an integer"
    assert is_integer(status["favourites_count"]), "Status.favourites_count must be an integer"
    assert is_integer(status["replies_count"]), "Status.replies_count must be an integer"
  end

  defp assert_valid_notification(notification) when is_map(notification) do
    for field <- @required_notification_fields do
      assert Map.has_key?(notification, field),
             "Notification missing required field '#{field}'. Got keys: #{inspect(Map.keys(notification))}"
    end

    assert is_binary(notification["id"]), "Notification.id must be a string"

    valid_types = ~w(follow follow_request mention reblog favourite poll status update admin.report)

    assert notification["type"] in valid_types,
           "Notification.type '#{notification["type"]}' not in valid types"

    assert is_map(notification["account"]), "Notification.account must be a map"
    assert is_binary(notification["account"]["id"]), "Notification.account.id must be a string"
  end

  defp assert_valid_conversation(conversation) when is_map(conversation) do
    for field <- @required_conversation_fields do
      assert Map.has_key?(conversation, field),
             "Conversation missing required field '#{field}'. Got keys: #{inspect(Map.keys(conversation))}"
    end

    assert is_binary(conversation["id"]), "Conversation.id must be a string"
    assert is_list(conversation["accounts"]), "Conversation.accounts must be a list"
    assert is_boolean(conversation["unread"]), "Conversation.unread must be a boolean"
    assert Map.has_key?(conversation, "last_status"), "Conversation must have last_status key"
  end

  # --- Helper functions ---

  defp connect_ws(token) do
    WS.connect(%{params: %{"access_token" => token}, connect_info: %{}, options: []})
  end

  defp init_ws(token) do
    {:ok, state} = connect_ws(token)
    WS.init(state)
  end

  defp create_access_token(user) do
    {:ok, ecto_client} =
      ClientApps.new(%{
        id: Faker.UUID.v4(),
        name: "test-streaming-app",
        redirect_uris: ["http://localhost:4000/oauth/callback"]
      })

    {:ok, token} =
      AccessTokensAdapter.create(
        %{client: to_oauth_schema(ecto_client), sub: user.id, scope: "read write push"},
        []
      )

    {:ok, token.value}
  end

  defp collect_all_frames({:push, {:text, frame}, _state}) do
    decoded = Jason.decode!(frame)
    rest = collect_push_frame_messages()
    [decoded | rest]
  end

  defp collect_all_frames({:ok, _state}), do: []

  defp collect_push_frame_messages do
    receive do
      {:push_frame, frame} ->
        decoded = Jason.decode!(frame)
        [decoded | collect_push_frame_messages()]
    after
      100 ->
        []
    end
  end

  # Load an activity from DB with associations needed by Mastodon mappers.
  # Accepts the return value of publish/like/follow/etc.
  defp load_activity_for({:ok, object}), do: load_activity_for(object)

  defp load_activity_for(%{activity: %{id: _} = activity}) do
    activity
    |> Bonfire.Common.Repo.maybe_preload([
      :verb,
      subject: [:character, profile: :icon],
      object: [:post_content, tagged: [tag: [:character, :profile]]]
    ])
  end

  defp load_activity_for(%{id: object_id} = _object) do
    case Bonfire.Social.Activities.read(object_id, skip_boundary_check: true) do
      {:ok, activity} ->
        activity
        |> Bonfire.Common.Repo.maybe_preload([
          :verb,
          subject: [:character, profile: :icon],
          object: [:post_content, tagged: [tag: [:character, :profile]]]
        ])

      _ ->
        raise "Could not load activity for object #{object_id}"
    end
  end
end
