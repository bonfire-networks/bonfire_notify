defmodule Bonfire.Notify.Web.MastoStreamingWebSocket do
  @moduledoc """
  Raw WebSocket transport implementing Mastodon's streaming API at `/api/v1/streaming`.

  Unlike Phoenix Channels, Mastodon clients send/receive plain JSON frames:

      Client → Server: {"type":"subscribe","stream":"user"}
      Server → Client: {"stream":["user"],"event":"update","payload":"{...}"}

  This module implements `Phoenix.Socket.Transport` directly, handling OAuth
  token validation on connect, PubSub subscription management, and event
  formatting via `Bonfire.Notify.MastoStreaming.EventFormatter`.

  ## Auth methods (in priority order)

  1. `access_token` query param (legacy)
  2. `Sec-WebSocket-Protocol` header (recommended by many clients)
  3. `Authorization: Bearer` header

  ## Supported stream types

  - `"user"` — home timeline + notifications for the authenticated user
  - `"user:notification"` — notifications only
  - `"public"` — public/guest feed (all federated public posts)
  - `"public:local"` — local instance feed
  - `"public:media"` / `"public:local:media"` — media variants (same topics for now)
  - `"public:remote"` / `"public:remote:media"` — remote/federated feed
  - `"direct"` — DMs (inbox feed)
  - `"hashtag"` — per-hashtag stream (requires `tag` param, stub)
  - `"hashtag:local"` — local hashtag variant (stub)
  - `"list"` — per-list stream (requires `list` param, stub)
  """

  @behaviour Phoenix.Socket.Transport

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.MastoStreaming.EventFormatter
  alias Boruta.Oauth.Authorization.AccessToken

  @heartbeat_interval_ms 30_000

  # Notification types that include a status object per Mastodon spec
  @notification_types_with_status ~w(mention status reblog favourite poll update)

  # --- Transport callbacks ---

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{params: params} = transport_info) do
    token_value = resolve_token(params, transport_info)

    with {:ok, token} when token.sub != nil <- validate_token(token_value),
         %{} = user <- Bonfire.Me.Users.get_current(token.sub),
         user <- repo().maybe_preload(user, :character) do
      state = %{
        user: user,
        subscriptions: %{},
        notification_feed_id: nil
      }

      # If `stream` param provided, queue immediate subscription after init
      state =
        case params["stream"] do
          stream when is_binary(stream) and stream != "" ->
            Map.put(state, :initial_stream, {stream, params["tag"], params["list"]})

          _ ->
            state
        end

      debug(Bonfire.Common.Enums.id(user), "[MastoWS] Connected user")
      {:ok, state}
    else
      _ ->
        debug("[MastoWS] Connection rejected: invalid or missing token")
        :error
    end
  end

  def connect(_), do: :error

  @impl true
  def init(state) do
    debug("[MastoWS] init/1 called")

    # Schedule periodic heartbeat
    schedule_heartbeat()

    # Handle initial stream subscription from query params
    state =
      case Map.pop(state, :initial_stream) do
        {nil, state} ->
          state

        {{stream, tag, list}, state} ->
          subscribe_to_stream(state, stream, tag: tag, list: list)
      end

    debug("[MastoWS] init/1 completed")
    {:ok, state}
  end

  @impl true
  def handle_in({text, _opts}, state) do
    debug(text, "[MastoWS] handle_in received")

    case Jason.decode(text) do
      {:ok, %{"type" => "subscribe", "stream" => stream} = msg} when is_binary(stream) ->
        state = subscribe_to_stream(state, stream, tag: msg["tag"], list: msg["list"])
        {:ok, state}

      {:ok, %{"type" => "unsubscribe", "stream" => stream} = msg} when is_binary(stream) ->
        stream_key = subscription_key(stream, msg["tag"], msg["list"])
        state = unsubscribe_from_stream(state, stream_key)
        {:ok, state}

      {:ok, _other} ->
        # Unknown message type, ignore per Mastodon spec
        {:ok, state}

      {:error, _} ->
        # Malformed JSON, ignore
        {:ok, state}
    end
  end

  @impl true
  def handle_info(
        {{Bonfire.Social.Feeds, :new_activity}, data},
        state
      ) do
    feed_ids = List.wrap(data[:feed_ids])
    activity = data[:activity]
    feed_id_strs = Enum.map(feed_ids, &to_string/1)

    frames =
      Enum.reduce(state.subscriptions, [], fn {stream_name, topic}, acc ->
        if to_string(topic) in feed_id_strs do
          case EventFormatter.format_update(activity, current_user: state.user) do
            {:ok, payload} ->
              frame = EventFormatter.to_ws_frame(to_stream_array(stream_name), "update", payload)
              debug("[MastoWS] pushing update frame (#{byte_size(frame)} bytes)")
              [frame | acc]

            :skip ->
              debug("[MastoWS] format_update returned :skip")
              acc
          end
        else
          acc
        end
      end)

    debug("[MastoWS] pushing #{length(frames)} frames")
    push_frames(frames, state)
  end

  def handle_info({:push_frame, frame}, state) do
    {:push, {:text, frame}, state}
  end

  def handle_info({Bonfire.UI.Common.Notifications, _data}, state) do
    # Ignore simplified notification format — we use :new_activity for rich data
    {:ok, state}
  end

  def handle_info({:new_message, %{thread_id: thread_id}}, state) do
    # DM / conversation event
    if Map.has_key?(state.subscriptions, "direct") do
      {:ok, payload} = EventFormatter.format_conversation(thread_id, current_user: state.user)
      frame = EventFormatter.to_ws_frame(["direct"], "conversation", payload)
      {:push, {:text, frame}, state}
    else
      {:ok, state}
    end
  end

  def handle_info(:heartbeat, state) do
    schedule_heartbeat()
    # Phoenix handles WebSocket ping/pong automatically at the transport level,
    # so we just reschedule without pushing an empty text frame (which can cause
    # some clients like websocat to disconnect)
    {:ok, state}
  end

  def handle_info(other, state) do
    debug("[MastoWS] unhandled message: #{inspect(other, limit: 200)}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, _state) do
    debug(reason, "[MastoWS] terminate")
    :ok
  end

  # --- Private helpers ---

  defp resolve_token(params, transport_info) do
    # Token resolution order (first non-nil wins):
    # 1. access_token query param (legacy)
    # 2. Sec-WebSocket-Protocol header value (used by many Mastodon clients)
    # 3. Authorization: Bearer header
    params["access_token"] ||
      extract_sec_websocket_protocol_token(transport_info) ||
      extract_bearer_token(transport_info)
  end

  defp extract_sec_websocket_protocol_token(%{connect_info: connect_info}) do
    case get_in(connect_info, [:sec_websocket_headers, "sec-websocket-protocol"]) do
      nil -> nil
      "" -> nil
      token when is_binary(token) -> token
    end
  rescue
    _ -> nil
  end

  defp extract_sec_websocket_protocol_token(_), do: nil

  defp extract_bearer_token(%{connect_info: connect_info}) do
    headers = connect_info[:x_headers] || []

    Enum.find_value(headers, fn
      {"authorization", "Bearer " <> token} -> token
      _ -> nil
    end)
  rescue
    _ -> nil
  end

  defp extract_bearer_token(_), do: nil

  defp validate_token(nil), do: :error
  defp validate_token(""), do: :error

  defp validate_token(token_value) do
    case AccessToken.authorize(value: token_value) do
      {:ok, token} -> {:ok, token}
      _ -> :error
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  @doc false
  def subscription_key(stream, tag, list) do
    cond do
      stream in ["hashtag", "hashtag:local"] and is_binary(tag) and tag != "" ->
        "#{stream}:#{tag}"

      stream == "list" and is_binary(list) and list != "" ->
        "list:#{list}"

      true ->
        stream
    end
  end

  defp subscribe_to_stream(state, stream_name, opts \\ []) do
    tag = Keyword.get(opts, :tag)
    list = Keyword.get(opts, :list)
    stream_key = subscription_key(stream_name, tag, list)

    if Map.has_key?(state.subscriptions, stream_key) do
      # Already subscribed
      state
    else
      case resolve_topic(stream_name, state.user) do
        nil ->
          debug(stream_key, "[MastoWS] Could not resolve topic for stream")
          state

        topic ->
          topic_str = to_string(topic)
          Phoenix.PubSub.subscribe(Bonfire.Common.PubSub, topic_str)

          debug("[MastoWS] Subscribed to #{stream_key} (topic: #{topic_str})")

          subscriptions = Map.put(state.subscriptions, stream_key, topic)

          # Track notification feed ID so we can distinguish notification vs update events
          notification_feed_id =
            if stream_name in ["user", "user:notification"] do
              topic
            else
              state.notification_feed_id
            end

          %{state | subscriptions: subscriptions, notification_feed_id: notification_feed_id}
      end
    end
  end

  defp unsubscribe_from_stream(state, stream_key) do
    case Map.pop(state.subscriptions, stream_key) do
      {nil, _} ->
        state

      {topic, remaining} ->
        Phoenix.PubSub.unsubscribe(Bonfire.Common.PubSub, to_string(topic))
        debug("[MastoWS] Unsubscribed from #{stream_key}")

        notification_feed_id =
          if stream_key in ["user", "user:notification"] do
            nil
          else
            state.notification_feed_id
          end

        %{state | subscriptions: remaining, notification_feed_id: notification_feed_id}
    end
  end

  defp resolve_topic(stream_name, user) do
    case stream_name do
      "user" ->
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.Social.Feeds,
          :my_feed_id,
          [:notifications, user]
        )

      "user:notification" ->
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.Social.Feeds,
          :my_feed_id,
          [:notifications, user]
        )

      "public" ->
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.Social.Feeds,
          :named_feed_id,
          [:guest]
        )

      "public:local" ->
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.Social.Feeds,
          :named_feed_id,
          [:local]
        )

      # Media variants map to same topics (media filtering is a TODO)
      "public:media" ->
        resolve_topic("public", user)

      "public:local:media" ->
        resolve_topic("public:local", user)

      # Remote/federated feed
      "public:remote" ->
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.Social.Feeds,
          :named_feed_id,
          [:activity_pub]
        )

      "public:remote:media" ->
        resolve_topic("public:remote", user)

      "direct" ->
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.Social.Feeds,
          :my_feed_id,
          [:inbox, user]
        )

      # Stubs: accepted but no PubSub topic exists yet
      "hashtag" ->
        nil

      "hashtag:local" ->
        nil

      "list" ->
        nil

      other ->
        debug(other, "[MastoWS] Unknown stream type")
        nil
    end
  end

  # Emit both notification and (if applicable) update events for the user stream
  defp emit_notification_and_maybe_update(stream_name, activity, state, acc) do
    stream_arr = to_stream_array(stream_name)

    acc =
      case EventFormatter.format_notification(activity, current_user: state.user) do
        {:ok, payload} ->
          frame = EventFormatter.to_ws_frame(stream_arr, "notification", payload)
          [frame | acc]

        :skip ->
          acc
      end

    # Per Mastodon spec: user stream also emits update events when the notification
    # type includes a status (mention, reblog, favourite, poll, status, update)
    notification_type = detect_notification_type(activity)

    if notification_type in @notification_types_with_status do
      case EventFormatter.format_update(activity, current_user: state.user) do
        {:ok, payload} ->
          frame = EventFormatter.to_ws_frame(stream_arr, "update", payload)
          [frame | acc]

        :skip ->
          acc
      end
    else
      acc
    end
  end

  defp detect_notification_type(activity) do
    if Code.ensure_loaded?(Bonfire.API.MastoCompat.Mappers.Notification) do
      verb_id = get_verb_id(activity)
      Bonfire.API.MastoCompat.Mappers.Notification.map_verb_to_type(verb_id)
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp get_verb_id(%{verb: %{verb: verb_id}}) when is_binary(verb_id), do: verb_id
  defp get_verb_id(%{verb_id: verb_id}) when is_binary(verb_id), do: verb_id
  defp get_verb_id(%{verb: verb_id}) when is_binary(verb_id), do: verb_id
  defp get_verb_id(_), do: nil

  @doc """
  Convert a subscription key to the Mastodon stream array format.

  Per spec, stream arrays use separate elements for parameters:
  - `"user"` → `["user"]`
  - `"hashtag:elixir"` → `["hashtag", "elixir"]`
  - `"list:42"` → `["list", "42"]`
  - `"public:local"` → `["public:local"]` (colon is part of stream name, not a param)
  """
  def to_stream_array(stream_key) do
    cond do
      String.starts_with?(stream_key, "hashtag:local:") ->
        tag = String.replace_prefix(stream_key, "hashtag:local:", "")
        ["hashtag:local", tag]

      String.starts_with?(stream_key, "hashtag:") ->
        tag = String.replace_prefix(stream_key, "hashtag:", "")
        ["hashtag", tag]

      String.starts_with?(stream_key, "list:") ->
        list_id = String.replace_prefix(stream_key, "list:", "")
        ["list", list_id]

      true ->
        [stream_key]
    end
  end

  defp push_frames([], state), do: {:ok, state}
  defp push_frames([single], state), do: {:push, {:text, single}, state}

  defp push_frames(multiple, state) do
    # Send each frame. Phoenix transport only supports one push per handle_info,
    # so send remaining via Process messaging
    [first | rest] = Enum.reverse(multiple)

    for frame <- rest do
      send(self(), {:push_frame, frame})
    end

    {:push, {:text, first}, state}
  end
end
