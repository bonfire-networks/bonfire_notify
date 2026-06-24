defmodule Bonfire.Notify do
  @moduledoc """
  Public API for sending notifications.

  This module provides a simple entrypoint that delegates to the underlying
  notification system (WebPush/native push for push notifications, LivePush for in-app notifications).
  """

  use Application
  use Bonfire.Common.Utils
  import Untangle
  import Ecto.Query

  alias Bonfire.Notify.NativePush
  alias Bonfire.Notify.WebPush

  def start(_, _) do
    :telemetry.attach(
      "bonfire_notify_vapid_setup",
      [:settings, :load_config, :stop],
      fn _event, _measurements, _meta, _config ->
        :telemetry.detach("bonfire_notify_vapid_setup")
        Bonfire.Notify.maybe_generate_keys()
      end,
      nil
    )

    Supervisor.start_link([], strategy: :one_for_one)
  end

  declare_extension(
    "Notifications",
    icon: "ph:device-mobile",
    description: l("Manage your notification settings and registered devices")
  )

  def enabled? do
    Application.get_env(:ex_nudge, :vapid_public_key) != nil and
      Application.get_env(:ex_nudge, :vapid_private_key) != nil
  end

  @doc """
  Generates VAPID keys for web push notifications if none are configured.

  Called after `Bonfire.Common.Settings.LoadInstanceConfig` completes (via telemetry hook),
  so DB-stored keys are already loaded into OTP config before we check.
  Generated keys are persisted to instance settings so they survive restarts.
  """
  def maybe_generate_keys do
    unless Bonfire.Notify.enabled?() do
      info("Generating VAPID keys for web push notifications")
      keys = ExNudge.VAPID.generate_vapid_keys()

      # Persists to DB and also updates OTP config in-process via Config.put_tree,
      # so keys are immediately available via Application.get_env(:ex_nudge, ...)
      Bonfire.Common.Settings.put([:ex_nudge, :vapid_public_key], keys.public_key,
        scope: :instance,
        skip_boundary_check: true
      )

      Bonfire.Common.Settings.put([:ex_nudge, :vapid_private_key], keys.private_key,
        scope: :instance,
        skip_boundary_check: true
      )
    end
  end

  @doc """
  Sends a notification about an object to a user or list of users.

  This is a convenience function that:
  - Records the notification in the database
  - Sends web push notifications to subscribed devices
  - Formats the notification message appropriately

  ## Examples

      # Notify a single user
      notify(post, user)
      
      # Notify multiple users
      notify(reply, [user1, user2, user3])
  """
  def notify(object, %{} = user) do
    notify(object, [user])
  end

  def notify(object, subscribers) when is_list(subscribers) do
    debug(object, "📨 Bonfire.Notify.notify called with object")
    debug(subscribers, "📨 Subscribers")

    if enabled?() or NativePush.configured?() do
      send_push_notifications(object, subscribers)
    else
      error("📨 Push disabled - no web or native push configuration")
      {:error, :disabled}
    end
  end

  defp send_push_notifications(object, subscribers) do
    creator = Map.get(object, :creator, %{})
    # `from_id` identifies the account that triggered the notification, used by
    # WebPush to enforce each subscription's policy (followed/follower/none).
    from_id = Map.get(object, :from_id) || uid(creator)
    category = Map.get(object, :notify_category)

    user_ids =
      subscribers
      |> Enum.map(&uid/1)
      |> Enum.reject(&(is_nil(&1) or &1 == from_id))
      |> filter_by_push_preferences(category)

    debug(user_ids, "📨 User IDs after filtering")

    if user_ids != [] do
      message = format_message_from(object, creator)
      debug(message, "📨 Formatted push message JSON")

      result =
        send_to_push_channels(user_ids, message, notify_category: category, from_id: from_id)

      debug(result, "📨 push delivery result")
      result
    else
      debug("📨 no_valid_recipients: No valid user IDs after filtering")
      {:error, :no_valid_recipients}
    end
  end

  defp filter_by_push_preferences(ids, nil), do: ids
  defp filter_by_push_preferences([], _), do: []

  defp filter_by_push_preferences(ids, category) do
    user_ids =
      case WebPush.resolve_feed_ids_to_user_ids(ids) do
        [] -> ids
        resolved -> resolved
      end

    from(u in Bonfire.Data.Identity.User,
      where: u.id in ^user_ids,
      preload: [:settings]
    )
    |> Bonfire.Common.Repo.many()
    |> Enum.filter(
      &Bonfire.Common.Settings.get([:push_notifications, category], true, context: &1)
    )
    |> Enum.map(&uid/1)
  end

  defp send_to_push_channels(user_ids, message, opts) do
    web_result =
      if enabled?() do
        WebPush.send_web_push(user_ids, message, opts)
      else
        {:error, :disabled}
      end

    native_result =
      if NativePush.configured?() do
        NativePush.send_native_push(user_ids, message, opts)
      else
        {:error, :native_push_not_configured}
      end

    debug(native_result, "📨 NativePush.send_native_push result")

    if enabled?() do
      web_result
    else
      native_result
    end
  end

  defp format_message_from(%{title: title, message: body} = assigns, _creator) do
    # Pre-formatted preview_assigns from LivePush — use directly
    WebPush.format_push_message(
      title,
      body || "New notification",
      url: assigns[:url],
      tag: assigns[:tag]
    )
  end

  defp format_message_from(object, creator) do
    # Raw object struct — extract content
    format_push_message(object, creator)
  end

  @doc """
  Formats a notification message for web push.

  This creates a JSON payload compatible with the Web Push API and
  browser notification display.
  """
  def format_push_message(object, creator, opts \\ []) do
    title =
      e(object, :name, nil) ||
        e(creator, :profile, :name, nil) ||
        e(creator, :character, :username, "Someone")

    body =
      e(object, :summary, nil) ||
        e(object, :post_content, :summary, nil) ||
        e(object, :post_content, :name, nil) ||
        Text.text_only(e(object, :post_content, :html_body, "")) ||
        "New notification"

    WebPush.format_push_message(
      title,
      body,
      Keyword.merge(
        [
          url: e(object, :canonical_url, nil) || e(object, :url, nil),
          tag: e(object, :id, nil)
        ],
        opts
      )
    )
  end

  @doc """
  Sends push notifications to specific user IDs.

  This is a convenience wrapper around configured push channels.
  """
  def push_to_users(user_ids, message, opts \\ []) when is_list(user_ids) do
    send_to_push_channels(user_ids, message, opts)
  end
end
