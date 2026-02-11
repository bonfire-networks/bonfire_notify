defmodule Bonfire.Notify.Web.StreamingControllerTest do
  @moduledoc """
  Tests for the SSE streaming controller API.

  Calls the controller directly with a test conn, broadcasts PubSub
  messages, then sends :stop_streaming to get the conn back and read
  the accumulated SSE chunks from the Plug test adapter.

  Run with: just test extensions/bonfire_notify/test/api/streaming_test.exs
  """

  use Bonfire.Notify.ConnCase, async: false

  alias Bonfire.Me.Fake
  alias Bonfire.Social.Feeds
  alias Bonfire.Notify.Web.StreamingController

  @moduletag :streaming

  setup do
    account = Fake.fake_account!()
    me = Fake.fake_user!(account)

    {:ok, me: me}
  end

  # Builds a GET conn with :current_user assigned (simulating the auth pipeline).
  defp streaming_conn(user) do
    Phoenix.ConnTest.build_conn(:get, "/api/v1-bonfire/streaming")
    |> Plug.Conn.assign(:current_user, user)
  end

  # Starts the controller in a Task. Returns {task, topic} so the test
  # can broadcast PubSub messages and then call stop_and_read_chunks/1.
  defp start_streaming(user) do
    conn = streaming_conn(user)
    topic = notification_topic(user)

    task =
      Task.async(fn ->
        StreamingController.stream(conn, %{})
      end)

    # Wait for send_chunked, then give the controller time to
    # finish PubSub.subscribe before the test broadcasts
    assert_receive {:plug_conn, :sent}, 2_000
    Process.sleep(200)

    {task, topic}
  end

  # Sends :stop_streaming to break the controller's receive loop,
  # awaits the Task, and returns the accumulated SSE chunk data.
  defp stop_and_read_chunks(task) do
    send(task.pid, :stop_streaming)
    conn = Task.await(task, 5_000)

    # The Plug test adapter accumulates chunks in adapter state
    {_, %{chunks: chunks}} = conn.adapter
    chunks
  end

  # Returns the notification feed topic string for a user.
  defp notification_topic(user) do
    feed_id = Feeds.my_feed_id(:notifications, user)
    assert feed_id, "user should have a notification feed"
    to_string(feed_id)
  end

  describe "SSE response headers" do
    test "returns 200 chunked with text/event-stream content type", %{me: me} do
      conn = streaming_conn(me)

      task =
        Task.async(fn ->
          StreamingController.stream(conn, %{})
        end)

      assert_receive {:plug_conn, :sent}, 2_000

      send(task.pid, :stop_streaming)
      result_conn = Task.await(task, 5_000)

      assert result_conn.status == 200
      assert result_conn.state == :chunked

      assert Plug.Conn.get_resp_header(result_conn, "content-type")
             |> Enum.any?(&(&1 =~ "text/event-stream"))

      assert Plug.Conn.get_resp_header(result_conn, "cache-control") == ["no-cache"]
      assert Plug.Conn.get_resp_header(result_conn, "x-accel-buffering") == ["no"]
    end
  end

  describe "SSE notification event from PubSub broadcast" do
    test "formats notification as SSE event: notification with correct JSON", %{me: me} do
      {task, topic} = start_streaming(me)

      Phoenix.PubSub.broadcast(
        Bonfire.Common.PubSub,
        topic,
        {Bonfire.UI.Common.Notifications,
         %{
           title: "New mention",
           message: "Alice mentioned you",
           url: "/post/42",
           icon: "https://example.com/avatar.png"
         }}
      )

      # Let the controller process the message
      Process.sleep(100)
      chunks = stop_and_read_chunks(task)

      # Verify SSE wire format
      assert chunks =~ "event: notification\n"
      assert chunks =~ "data: "

      [_, json_part] = String.split(chunks, "data: ", parts: 2)
      decoded = Jason.decode!(String.trim(json_part))

      assert decoded["title"] == "New mention"
      assert decoded["body"] == "Alice mentioned you"
      assert decoded["url"] == "/post/42"
      assert decoded["icon"] == "https://example.com/avatar.png"
    end

    test "formats DM as SSE event: message with thread_id", %{me: me} do
      {task, topic} = start_streaming(me)

      Phoenix.PubSub.broadcast(
        Bonfire.Common.PubSub,
        topic,
        {:new_message, %{feed_ids: [topic], thread_id: "thread_xyz"}}
      )

      Process.sleep(100)
      chunks = stop_and_read_chunks(task)

      assert chunks =~ "event: message\n"

      [_, json_part] = String.split(chunks, "data: ", parts: 2)
      decoded = Jason.decode!(String.trim(json_part))

      assert decoded["type"] == "message"
      assert decoded["thread_id"] == "thread_xyz"
    end
  end

  describe "SSE events from real social actions" do
    test "like triggers an SSE notification event for the post author", %{me: me} do
      {task, _topic} = start_streaming(me)

      liker = Fake.fake_user!(Fake.fake_account!())

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "<p>A likeable post</p>"}},
          boundary: "public"
        )

      assert {:ok, _like} = Bonfire.Social.Likes.like(liker, post)

      # Give the notification pipeline time to broadcast
      Process.sleep(500)
      chunks = stop_and_read_chunks(task)

      assert chunks =~ "event: notification\n"
      assert chunks =~ "data: "

      [_, json_part] = String.split(chunks, "data: ", parts: 2)
      decoded = Jason.decode!(String.trim(json_part))

      assert decoded["title"] || decoded["body"],
             "like notification should have a title or body"
    end

    test "DM triggers an SSE message event for the recipient", %{me: me} do
      sender = Fake.fake_user!(Fake.fake_account!())
      inbox_feed_id = Feeds.my_feed_id(:inbox, me)

      if inbox_feed_id do
        conn = streaming_conn(me)

        # Subscribe the controller's process to the inbox feed too
        # (simulating a controller that listens to both notification + inbox)
        task =
          Task.async(fn ->
            Phoenix.PubSub.subscribe(
              Bonfire.Common.PubSub,
              to_string(inbox_feed_id)
            )

            StreamingController.stream(conn, %{})
          end)

        assert_receive {:plug_conn, :sent}, 2_000
        Process.sleep(100)

        {:ok, _message} =
          Bonfire.Messages.send(
            sender,
            %{post_content: %{html_body: "Hey, this is a private message!"}},
            [me.id]
          )

        Process.sleep(500)
        chunks = stop_and_read_chunks(task)

        assert chunks =~ "event: message\n"

        [_, json_part] = String.split(chunks, "data: ", parts: 2)
        decoded = Jason.decode!(String.trim(json_part))

        assert decoded["type"] == "message"
      end
    end
  end
end
