defmodule Bonfire.Notify.LiveHandler do
  @moduledoc """
  Handles push notification events for LiveView components.
  """

  use Bonfire.UI.Common.Web, :live_handler
  import Untangle

  alias Bonfire.Notify.WebPush

  def mount(socket) do
    assign(socket, load_subscriptions(socket))
  end

  @doc """
  Helper to load subscriptions for current user in mount.
  Returns assigns to merge into socket.
  """
  def load_subscriptions(socket) do
    if vapid_public_key = Application.get_env(:ex_nudge, :vapid_public_key) do
      current_user = current_user(socket)

      subscriptions =
        if current_user do
          WebPush.list_subscriptions(id(current_user))
        else
          []
        end

      [
        vapid_public_key: vapid_public_key,
        is_pwa: false,
        subscription_size: Enum.count(subscriptions),
        subscriptions: subscriptions
      ]
    else
      []
    end
  end

  def handle_event("subscribe", %{"subscription" => subscription_data}, socket) do
    current_user = current_user(socket)

    if current_user do
      case WebPush.subscribe(id(current_user), subscription_data) do
        {:ok, subscription} ->
          broadcast_device_added(subscription)

          # the confirmation IS a push, so turning it on proves the whole chain at the moment someone cares. It also surfaces the layer browser permission does not cover: an operating system can suppress a browser's notifications entirely (macOS asks per browser), so permission can be granted and nothing ever appears
          case confirm_by_pushing(subscription, id(current_user)) do
            :ok ->
              {:noreply,
               assign_flash(
                 socket,
                 :info,
                 l(
                   "Notifications are on. You should see a test notification now: if you don't, check whether your system and browser settings allow notifications from here."
                 )
               )}

            other ->
              error(other, "Subscribed, but the push service would not take a test notification")

              {:noreply,
               assign_flash(
                 socket,
                 :error,
                 l(
                   "Notifications are on, but a test notification could not seem to reach this device. Ignore this if the notification did arrive, or check your system and browser settings if it didn't."
                 )
               )}
          end

        {:error, reason} ->
          error_msg = Bonfire.Common.Errors.error_msg(reason)
          {:noreply, assign_flash(socket, :error, "Subscription failed: #{error_msg}")}
      end
    else
      {:noreply, assign_flash(socket, :error, "You must be logged in to subscribe")}
    end
  end

  def handle_event("is-pwa", _params, socket) do
    {:noreply, assign(socket, :is_pwa, true)}
  end

  def handle_event("unsubscribe", %{"endpoint" => endpoint}, socket) do
    case WebPush.remove_subscription_by_endpoint(endpoint) do
      {count, _} when count > 0 ->
        # repo().delete_all returns {count, nil} — broadcast with a minimal struct for the endpoint
        broadcast_device_removed(%{endpoint: endpoint})
        {:noreply, assign_flash(socket, :info, "Device removed successfully!")}

      {0, _} ->
        {:noreply, assign_flash(socket, :error, "Failed to remove device: not found")}
    end
  end

  def handle_event("test_notification", %{"subscription_id" => subscription_id}, socket) do
    # scoped to whoever is asking, through the same read a delivery job does: the old path took a bare subscription id and sent to it, so anyone logged in could push to a subscription that wasn't theirs
    with {:ok, target} <- WebPush.target(subscription_id, uid(current_user_required!(socket))),
         :ok <-
           WebPush.deliver(target, %{
             title: l("Test notification"),
             body: l("If you can read this, push notifications work on this device.")
           }) do
      {:noreply, assign_flash(socket, :info, l("Test sent to this device"))}
    else
      {:error, :inactive} ->
        {:noreply, assign_flash(socket, :error, l("That device is no longer subscribed"))}

      other ->
        {:noreply,
         assign_flash(socket, :error, l("Could not send: %{reason}", reason: inspect(other)))}
    end
  end

  def handle_event("remove_subscription", %{"subscription_id" => subscription_id}, socket) do
    case WebPush.remove_subscription(subscription_id) do
      {:ok, sub} ->
        broadcast_device_removed(sub)
        {:noreply, assign_flash(socket, :info, "Device removed")}

      {:error, reason} ->
        {:noreply, assign_flash(socket, :error, "Failed to remove device: #{reason}")}
    end
  end

  def handle_event("refresh_subscriptions", _params, socket) do
    current_user = current_user(socket)

    subscriptions =
      if current_user do
        WebPush.list_subscriptions(id(current_user))
      else
        []
      end

    {:noreply, stream(socket, :subscriptions, subscriptions, reset: true)}
  end

  def handle_info({:device_removed, %{endpoint: endpoint}}, socket) do
    {:noreply,
     socket
     |> assign(:subscription_size, max(0, socket.assigns.subscription_size - 1))
     |> push_event("device_removed", %{endpoint: endpoint})}
  end

  def handle_info({:device_removed, device}, socket) do
    {:noreply,
     socket
     |> stream_delete(:subscriptions, device)
     |> assign(:subscription_size, max(0, socket.assigns.subscription_size - 1))
     # the browser knows its own device by endpoint, so that is what the event carries
     |> push_event("device_removed", %{endpoint: device.address})}
  end

  def handle_info({:device_added, subscription}, socket) do
    {:noreply,
     socket
     |> stream_insert(:subscriptions, subscription)
     |> assign(:subscription_size, socket.assigns.subscription_size + 1)}
  end

  def handle_event("broadcast_open", %{"id" => object_id}, socket) do
    _current_user = current_user_required!(socket)

    with {:ok, object} <-
           Bonfire.Common.Needles.get(object_id,
             skip_boundary_check: true,
             preload: [:with_creator, :with_content]
           ) do
      quote_url = Bonfire.Common.URIs.canonical_url(object)

      if quote_url do
        Bonfire.UI.Common.SmartInput.LiveHandler.open_with_text_suggestion(
          "",
          [
            quoted_object: object,
            quoted_url: quote_url,
            smart_input_opts: %{create_object_type: :broadcast}
          ],
          socket
        )

        {:noreply, socket}
      else
        {:noreply, assign_error(socket, l("Could not generate URL for this post"))}
      end
    else
      _ ->
        {:noreply, assign_error(socket, l("Could not broadcast this post"))}
    end
  end

  def handle_event("broadcast", params, socket) do
    admin = current_user_required!(socket)

    with {:ok, published} <- Bonfire.Posts.LiveHandler.publish_post(params, socket),
         {:ok, _published, count} <-
           Bonfire.Notify.Broadcast.broadcast(admin, published, params) do
      {:noreply,
       socket
       |> Bonfire.UI.Common.SmartInput.LiveHandler.reset_input()
       |> assign_flash(
         :info,
         lp("Announcement sent to %{count} user!", "Announcement sent to %{count} users!", count,
           count: count
         )
       )}
    else
      e ->
        error(e, "Could not send announcement")
        {:noreply, assign_flash(socket, :error, l("Could not send the announcement"))}
    end
  end

  # Private helpers

  defp broadcast_device_removed(subscription) do
    Phoenix.PubSub.broadcast(
      Bonfire.Common.PubSub,
      "push_notifications",
      {:device_removed, subscription}
    )
  end

  defp broadcast_device_added(subscription) do
    Phoenix.PubSub.broadcast(
      Bonfire.Common.PubSub,
      "push_notifications",
      {:device_added, subscription}
    )
  end

  # sent through the same channel a real notification goes through, so what it proves is the real path rather than a simplified one
  defp confirm_by_pushing(%{push_device_id: push_device_id}, user_id) do
    with {:ok, target} <- WebPush.target(push_device_id, user_id) do
      WebPush.deliver(target, %{
        title: l("Notifications are working"),
        body: l("This is what a notification from here looks like.")
      })
    end
  end

  defp confirm_by_pushing(other, _user_id), do: error(other, "No subscription to confirm")
end
