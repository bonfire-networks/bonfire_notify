defmodule Bonfire.Notify do
  @moduledoc """
  Public API for sending notifications.

  This module provides a simple entrypoint that delegates to the underlying
  notification system (WebPush for push notifications, LivePush for in-app notifications).
  """

  use Application
  use Bonfire.Common.Utils
  import Untangle

  alias Bonfire.Notify.WebPush

  def vapid_config do
    Application.get_env(:ex_nudge, :vapid_details, []) ||
      Application.get_env(:web_push_encryption, :vapid_details, [])
  end

  def enabled? do
    case vapid_config() do
      [] ->
        false

      config when is_list(config) ->
        (config[:vapid_private_key] || config[:private_key]) != nil and
          (config[:vapid_public_key] || config[:public_key]) != nil

      _ ->
        false
    end
  end

  # Backward compatibility alias
  def enabled, do: enabled?()

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

    creator = Map.get(object, :creator, %{})

    # Send web push notifications
    if enabled?() do
      send_push_notifications(object, creator, subscribers)
    else
      error("📨 Web push disabled - VAPID keys not configured")
      {:error, :disabled}
    end
  end

  defp send_push_notifications(object, creator, subscribers) do
    # Get user IDs excluding the creator
    user_ids =
      subscribers
      |> Enum.reject(&(uid(&1) == uid(creator)))
      |> Enum.map(&uid/1)
      |> Enum.reject(&is_nil/1)

    debug(user_ids, "📨 User IDs after filtering")

    if user_ids != [] do
      # Format the push message
      message = format_push_message(object, creator)
      debug(message, "📨 Formatted push message JSON")

      # Send via WebPush
      result = WebPush.send_web_push(user_ids, message)
      debug(result, "📨 WebPush.send_web_push result")
      result
    else
      error("📨 no_valid_recipients: No valid user IDs after filtering")
      {:error, :no_valid_recipients}
    end
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

  This is a convenience wrapper around `WebPush.send_web_push/3`.
  """
  def push_to_users(user_ids, message, opts \\ []) when is_list(user_ids) do
    WebPush.send_web_push(user_ids, message, opts)
  end
end
