defmodule Bonfire.Notify.AppBannerLive do
  @moduledoc """
  The bottom card offering what this device can still get from Bonfire: installing it as an app, and push notifications. One card with a row each, so the two never stack, and one ✕ that hides it on this device for good.

  Only the browser knows whether either applies (an install prompt waiting, iOS needing the Share menu, `Notification.permission` never asked), so `AppBannerHook` works it out and sends `rows`; until then this renders an empty shell. The push row is `Bonfire.Notify.Settings.PushNotificationsLive` in its compact form, the one component that asks the browser and stores the subscription, mounted only once the hook says it applies, since on every page it would cost a round-trip per load for people who already decided.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  @doc "Whether this instance can send web push at all (VAPID keys), which the browser cannot know."
  data configured, :boolean, default: false

  data install, :boolean, default: false

  @doc "iOS has no install prompt, so the install row shows the Share menu steps instead of a button."
  data ios, :boolean, default: false
  data push, :boolean, default: false

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:configured, Bonfire.Notify.WebPush.configured?())}
  end

  def handle_event("rows", params, socket) do
    {:noreply,
     assign(socket,
       install: params["install"] == true,
       ios: params["ios"] == true,
       # guests get the install row too, while push needs someone to subscribe
       push:
         params["push"] == true and socket.assigns.configured and
           not is_nil(current_user(socket.assigns))
     )}
  end
end
