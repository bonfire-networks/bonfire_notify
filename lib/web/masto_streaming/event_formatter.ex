defmodule Bonfire.Notify.MastoStreaming.EventFormatter do
  @moduledoc """
  Formats PubSub activity data into Mastodon WebSocket streaming JSON frames.

  A status or a notification is read through GraphQL with the published activity as root
  (`Bonfire.API.MastoCompat.Helpers.run_published/4`), with the selection the timeline and the
  notification list use, then mapped by the same mappers, so a streamed entity is what a fetched
  one is. A conversation's sender is read by id through GraphQL (`Bonfire.API.MastoCompat.Accounts.by_ids/3`).

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

  Read through GraphQL with the activity as root (`published_status/2`).

  Returns `{:ok, json_string}` or `:skip` if the activity can't be mapped.
  """
  def format_update(activity, opts \\ []) do
    case status_map(activity, opts) do
      %{"id" => id} = status when not is_nil(id) -> {:ok, Jason.encode!(status)}
      _ -> :skip
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
    current_user = opts[:current_user]

    # the list's candidate and mapper, so a streamed notification is what a fetched one is (a quote's status is the quoting post, read as the viewer)
    notification =
      case Bonfire.Social.API.GraphQLMasto.Notifications.published_candidate(
             activity,
             current_user
           ) do
        %{} = candidate ->
          Mappers.Notification.from_candidate(candidate, current_user: current_user)

        _ ->
          nil
      end

    case notification do
      %{} = notification ->
        {:ok,
         notification
         |> Helpers.deep_struct_to_map(filter_nils: true, drop_unknown_structs: true)
         |> Jason.encode!()}

      _ ->
        :skip
    end

    # replaced by the list's candidate and mapper above: this built its own, without an account when the subject is not a person, and took every status from the activity's object
    # if notification_type do
    #   subject = e(activity, :subject, nil)
    #
    #   account =
    #     Mappers.Account.from_user(subject, skip_expensive_stats: true)
    #     |> Helpers.deep_struct_to_map(filter_nils: true, drop_unknown_structs: true)
    #
    #   notification = %{
    #     "id" => to_string(id(activity)),
    #     "type" => notification_type,
    #     "created_at" => format_datetime(e(activity, :created_at, nil) || DateTime.utc_now()),
    #     "account" => account
    #   }
    #
    #   notification =
    #     if Bonfire.API.MastoCompat.Schemas.Notification.with_status?(notification_type) do
    #       case lightweight_status_map(activity, opts) do
    #         nil -> notification
    #         status -> Map.put(notification, "status", status)
    #       end
    #     else
    #       notification
    #     end
    #
    #   {:ok, Jason.encode!(notification)}
    # else
    #   :skip
    # end
  rescue
    e ->
      error(e, "EventFormatter.format_notification failed")
      :skip
  end

  @doc """
  Format a conversation event using the Mastodon Conversation entity shape.

  Accepts either a bare `thread_id` or a `%{thread_id:, activity:}` map (as
  broadcast by `Bonfire.Social.LivePush`). When the message activity is present,
  the `last_status` and the participating `account` are populated from it.

  Returns `{:ok, json_string}`.
  """
  def format_conversation(thread_id_or_data, opts \\ [])

  def format_conversation(%{thread_id: thread_id} = data, opts) do
    activity = Map.get(data, :activity)
    build_conversation(thread_id, activity, opts)
  end

  def format_conversation(thread_id, opts) do
    build_conversation(thread_id, nil, opts)
  end

  defp build_conversation(thread_id, activity, opts) do
    last_status = activity && status_map(activity, opts)

    conversation =
      minimal_conversation(thread_id)
      |> Map.put("last_status", last_status)
      |> Map.put("accounts", conversation_accounts(last_status, activity, opts))

    {:ok, Jason.encode!(conversation)}
  rescue
    e ->
      error(e, "EventFormatter.format_conversation failed")
      # Fall back to the minimal shape so the client still gets a valid frame
      {:ok, Jason.encode!(minimal_conversation(thread_id))}
  end

  defp minimal_conversation(thread_id) do
    %{"id" => to_string(thread_id), "accounts" => [], "unread" => true, "last_status" => nil}
  end

  defp conversation_accounts(_last_status, nil, _opts), do: []

  # the sender is the last status's account, already read through GraphQL with it
  defp conversation_accounts(%{"account" => %{} = account}, _activity, _opts), do: [account]

  # no status to take it from: the sender read by id, as the fetched conversation reads it
  defp conversation_accounts(_last_status, activity, opts) do
    case e(activity, :subject_id, nil) || Types.uid(e(activity, :subject, nil)) do
      nil ->
        []

      subject_id ->
        Bonfire.API.MastoCompat.Accounts.by_ids([subject_id], opts[:current_user], counts: true)
        |> Map.get(subject_id)
        |> Mappers.Account.from_user()
        |> Helpers.deep_struct_to_map(filter_nils: true, drop_unknown_structs: true)
        |> List.wrap()
    end
  end

  # An activity as a Mastodon Status map, through GraphQL with the activity as root, or nil.
  defp status_map(activity, opts) do
    case Bonfire.Social.API.GraphQLMasto.Adapter.published_status(activity, opts[:current_user]) do
      status when is_map(status) and map_size(status) > 0 ->
        Helpers.deep_struct_to_map(status, filter_nils: true, drop_unknown_structs: true)

      _ ->
        nil
    end
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

  # replaced by `Mappers.Notification.type_for/2`, which names it as the notification list and push do: a verb table of its own, where every create was a `mention` (so a bell post streamed as one) and replies, asks and reports never streamed
  # defp detect_notification_type(activity) do
  #   verb = e(activity, :verb, :verb, nil) || e(activity, :verb_id, nil)
  #   like_id = Bonfire.Boundaries.Verbs.get_id!(:like)
  #   boost_id = Bonfire.Boundaries.Verbs.get_id!(:boost)
  #   follow_id = Bonfire.Boundaries.Verbs.get_id!(:follow)
  #   create_id = Bonfire.Boundaries.Verbs.get_id!(:create)
  #
  #   cond do
  #     verb in ["Like", like_id] -> "favourite"
  #     verb in ["Boost", "Announce", boost_id] -> "reblog"
  #     verb in ["Follow", follow_id] -> "follow"
  #     verb in ["Create", create_id] -> "mention"
  #     true -> nil
  #   end
  # end

  # only the notification this module used to build read it: `Mappers.Notification.from_activity/2` dates it now
  # defp format_datetime(%DateTime{} = dt) do
  #   DateTime.to_iso8601(dt)
  # end
  #
  # defp format_datetime(%NaiveDateTime{} = ndt) do
  #   ndt
  #   |> DateTime.from_naive!("Etc/UTC")
  #   |> DateTime.to_iso8601()
  # end
  #
  # defp format_datetime(str) when is_binary(str), do: str
  # defp format_datetime(_), do: DateTime.utc_now() |> DateTime.to_iso8601()
end
