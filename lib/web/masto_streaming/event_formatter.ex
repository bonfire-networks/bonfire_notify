defmodule Bonfire.Notify.MastoStreaming.EventFormatter do
  @moduledoc """
  Formats PubSub activity data into Mastodon WebSocket streaming JSON frames.

  Delegates to `Bonfire.API.MastoCompat.Mappers.Status` and
  `Bonfire.API.MastoCompat.Mappers.Account` for consistent serialization,
  using `lightweight: true` to skip DB queries unsuitable for the WebSocket process.

  ## Wire format (per Mastodon WebSocket spec)

      {"stream":["user"],"event":"update","payload":"{\"id\":...}"}

  The `payload` field is double-encoded JSON (a JSON string containing JSON).
  """

  import Untangle
  use Bonfire.Common.Utils

  alias Bonfire.API.MastoCompat.Mappers
  alias Bonfire.API.MastoCompat.Helpers

  @doc """
  Format an activity as a Mastodon `update` event (status JSON).

  Delegates to `Mappers.Status.from_activity/2` with `lightweight: true`
  to avoid DB queries in the WebSocket process.

  Returns `{:ok, json_string}` or `:skip` if the activity can't be mapped.
  """
  def format_update(activity, opts \\ []) do
    mapper_opts = Keyword.merge(opts, lightweight: true)

    case Mappers.Status.from_activity(activity, mapper_opts) do
      status when is_map(status) and map_size(status) > 0 ->
        status =
          Helpers.deep_struct_to_map(status, filter_nils: true, drop_unknown_structs: true)

        if status["id"], do: {:ok, Jason.encode!(status)}, else: :skip

      _ ->
        :skip
    end
  rescue
    e ->
      error(e, "EventFormatter.format_update failed")
      :skip
  end

  @doc """
  Format an activity as a Mastodon `notification` event.

  Returns `{:ok, json_string}` or `:skip` if the activity can't be mapped.
  """
  def format_notification(activity, opts \\ []) do
    notification_type = detect_notification_type(activity)

    if notification_type do
      subject = e(activity, :subject, nil)

      account =
        Mappers.Account.from_user(subject, skip_expensive_stats: true)
        |> Helpers.deep_struct_to_map(filter_nils: true, drop_unknown_structs: true)

      notification = %{
        "id" => to_string(id(activity)),
        "type" => notification_type,
        "created_at" => format_datetime(e(activity, :created_at, nil) || DateTime.utc_now()),
        "account" => account
      }

      # Add status inline for notification types that include one (no encode→decode round-trip)
      notification =
        if notification_type in ~w(mention status reblog favourite poll update) do
          mapper_opts = Keyword.merge(opts, lightweight: true)

          case Mappers.Status.from_activity(activity, mapper_opts) do
            status when is_map(status) and map_size(status) > 0 ->
              Map.put(
                notification,
                "status",
                Helpers.deep_struct_to_map(status,
                  filter_nils: true,
                  drop_unknown_structs: true
                )
              )

            _ ->
              notification
          end
        else
          notification
        end

      {:ok, Jason.encode!(notification)}
    else
      :skip
    end
  rescue
    e ->
      error(e, "EventFormatter.format_notification failed")
      :skip
  end

  @doc """
  Format a conversation event using the Mastodon Conversation entity shape.

  Returns `{:ok, json_string}`.
  """
  def format_conversation(thread_id, _opts \\ []) do
    conversation = %{
      "id" => to_string(thread_id),
      "accounts" => [],
      "unread" => true,
      "last_status" => nil
    }

    {:ok, Jason.encode!(conversation)}
  end

  @doc """
  Format a delete event. Returns `{:ok, id_string}`.
  """
  def format_delete(activity_id) do
    {:ok, to_string(activity_id)}
  end

  @doc """
  Build a complete Mastodon WebSocket JSON frame.
  """
  def to_ws_frame(stream_names, event_type, payload) do
    Jason.encode!(%{
      "stream" => List.wrap(stream_names),
      "event" => event_type,
      "payload" => payload
    })
  end

  # --- Private helpers ---

  defp detect_notification_type(activity) do
    verb = e(activity, :verb, :verb, nil) || e(activity, :verb_id, nil)
    like_id = Bonfire.Boundaries.Verbs.get_id!(:like)
    boost_id = Bonfire.Boundaries.Verbs.get_id!(:boost)
    follow_id = Bonfire.Boundaries.Verbs.get_id!(:follow)
    create_id = Bonfire.Boundaries.Verbs.get_id!(:create)

    cond do
      verb in ["Like", like_id] -> "favourite"
      verb in ["Boost", "Announce", boost_id] -> "reblog"
      verb in ["Follow", follow_id] -> "follow"
      verb in ["Create", create_id] -> "mention"
      true -> nil
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp format_datetime(str) when is_binary(str), do: str
  defp format_datetime(_), do: DateTime.utc_now() |> DateTime.to_iso8601()
end
