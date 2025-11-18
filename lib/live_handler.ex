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
          {:noreply, put_flash(socket, :info, "Device subscribed successfully!")}

        {:error, changeset} ->
          error_msg = format_changeset_errors(changeset)
          {:noreply, put_flash(socket, :error, "Subscription failed: #{error_msg}")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be logged in to subscribe")}
    end
  end

  def handle_event("is-pwa", _params, socket) do
    {:noreply, assign(socket, :is_pwa, true)}
  end

  def handle_event("unsubscribe", %{"endpoint" => endpoint}, socket) do
    case WebPush.remove_subscription_by_endpoint(endpoint) do
      {1, subscription} ->
        broadcast_device_removed(subscription)
        {:noreply, put_flash(socket, :info, "Device removed successfully!")}

      {0, error} ->
        {:noreply, put_flash(socket, :error, "Failed to remove device: #{error || "not found"}")}
    end
  end

  def handle_event("test_notification", %{"subscription_id" => subscription_id}, socket) do
    case WebPush.send_push_notification(
           subscription_id,
           format_message("Test Message 📩", "Test for subscription #{subscription_id}.")
         ) do
      {:ok, _response} ->
        {:noreply, put_flash(socket, :info, "Test sent to #{subscription_id}!")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Notification to #{subscription_id} failed: #{inspect(reason)}"
         )}
    end
  end

  def handle_event("broadcast_test_notification", _params, socket) do
    case WebPush.broadcast(
           format_message("Broadcasted Test Message! 📩", "🚀🚀🚀 Broadcasted Test Message 🚀🚀🚀")
         ) do
      results when is_list(results) ->
        successful_count =
          results
          |> Enum.count(fn
            {:ok, _, _} -> true
            {:error, _, _} -> false
          end)

        {:noreply, put_flash(socket, :info, "Test sent to #{successful_count} subscriptions")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Broadcast failed: #{inspect(reason)}")}
    end
  end

  def handle_event("remove_subscription", %{"subscription_id" => subscription_id}, socket) do
    case WebPush.remove_subscription(subscription_id) do
      {:ok, sub} ->
        broadcast_device_removed(sub)
        {:noreply, put_flash(socket, :info, "Device removed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove device: #{reason}")}
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

  def handle_info({:device_removed, subscription}, socket) do
    {:noreply,
     socket
     |> stream_delete(:subscriptions, subscription)
     |> assign(:subscription_size, max(0, socket.assigns.subscription_size - 1))
     |> push_event("device_removed", %{endpoint: subscription.endpoint})}
  end

  def handle_info({:device_added, subscription}, socket) do
    {:noreply,
     socket
     |> stream_insert(:subscriptions, subscription)
     |> assign(:subscription_size, socket.assigns.subscription_size + 1)}
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

  defp format_changeset_errors(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} ->
      "#{field}: #{message}"
    end)
  end

  defp format_message(title, body) do
    Jason.encode!(%{title: title, body: body})
  end
end
