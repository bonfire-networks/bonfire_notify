defmodule Bonfire.Notify.Live do
  @moduledoc """
  Delivery to whoever is connected right now: an open page, which shows it as a toast (and, with permission, as an OS pop-up), and the native app's SSE stream.

  It is what push falls back to wherever push does not work, so it follows the same switch (`Bonfire.Notify.Preferences`' `channels` config maps it to `:push`), and it is a channel so that the fan-out decides it like the others: who can still see the activity, who has not seen it yet, what it was for each of them, and whether they want that kind.

  Unlike the push channels it is immediate (`immediate?/0`): a notification shown late is worth nothing and there is no device to retry, so `Bonfire.Notify.Deliveries` broadcasts it there and then rather than queuing a job. A client that is not connected simply does not hear it.

  A connected client listens on the person's own feeds (`Bonfire.UI.Common.NotificationLive` on the notifications feed, the SSE stream on that and the inbox), so that is where it goes: the inbox for a direct message, the notifications feed for everything else.
  """
  @behaviour Bonfire.Notify.Channel

  use Bonfire.Common.E
  import Untangle

  @impl Bonfire.Notify.Channel
  def configured?, do: true

  @impl Bonfire.Notify.Channel
  def immediate?, do: true

  @doc """
  Each person as their own target, with no query: where they are listening is on the recipient the fan-out already loaded (`Bonfire.Notify.Recipients` loads their character), which `Bonfire.Notify.Deliveries` hands to `deliver/3`.

  The verb is not used: a connection has no switches of its own, so the person's settings, already asked by the fan-out, are all there is.
  """
  @impl Bonfire.Notify.Channel
  def targets(user_ids, _verb \\ nil) when is_list(user_ids),
    do: Enum.map(user_ids, &%{user_id: &1, target_id: &1})

  @doc "Nothing to re-read: a connection is not stored, so there is no target to go stale between fan-out and delivery."
  @impl Bonfire.Notify.Channel
  def target(user_id, user_id), do: {:ok, %{user_id: user_id}}
  def target(_target_id, _user_id), do: {:error, :inactive}

  @doc """
  Broadcasts one notification to the feed this person's connected clients listen on.

  Sent already worded, in the language `Bonfire.Notify.Deliveries` assembled it in, as the fields a connected client shows (`Bonfire.UI.Common.Notifications.notification_fields/1` passes these through). `verb` stays out, since a message carrying one is taken for parts still to be put into words.
  """
  @impl Bonfire.Notify.Channel
  def deliver(target, content, _opts \\ []) do
    case feed_id(target) do
      nil ->
        {:cancel, :no_feed}

      feed_id ->
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.UI.Common.Notifications,
          :notify_broadcast,
          [[feed_id], shown(content)],
          fallback_return: nil
        )

        :ok
    end
  rescue
    exception ->
      # a connection that could not be told must not stop the other channels' deliveries
      error(exception, "Could not deliver a notification live")
      {:error, exception}
  end

  # from the recipient's loaded character, which is where both feed ids live
  defp feed_id(target) do
    if to_string(e(target, :feed, :notifications)) == "inbox",
      do: e(target, :user, :character, :inbox_id, nil),
      else: e(target, :user, :character, :notifications_id, nil)
  end

  defp shown(content) do
    %{
      title: e(content, :title, nil),
      message: e(content, :body, nil),
      icon: e(content, :icon, nil),
      url: e(content, :url, nil),
      tag: e(content, :tag, nil),
      activity_id: e(content, :activity_id, nil)
    }
  end
end
