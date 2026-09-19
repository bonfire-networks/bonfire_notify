defmodule Bonfire.Notify.Settings.PushNotificationsLive do
  @moduledoc """
  User settings component for push notifications.
  Allows users to enable/disable push notifications and manage registered devices.
  """

  # TODO: deduplicate with `Bonfire.Notify.PushNotifyLive`

  use Bonfire.UI.Common.Web, :stateful_component

  # NOTE:not a settings section of its own any more: it is one section of the notification preferences panel, which is what settings now shows (`Bonfire.Notify.Settings.NotificationPreferencesLive` places that panel here). Declaring both would put these same controls on the page twice, each with its own copy of the browser hook
  # declare_settings_component(l("Push Notifications"),
  #   icon: "ph:device-mobile",
  #   description: l("Manage your push notification settings and registered devices")
  # )

  alias Bonfire.Notify.UserPushSubscription
  alias Bonfire.Notify.WebPush

  prop scope, :any, default: nil

  @doc """
  How much of this to show: `:full` manages every device, `:compact` is only an offer to turn push on here.

  One component either way, because enabling push means asking the browser and keeping a subscription, and a second copy of that could only be a fake. The compact form is for places that are not about settings (a prompt beside the notifications, onboarding widget, etc), so it shows nothing once this browser is subscribed, and asks for no device list, since listing devices is the one part that costs a query.
  """
  prop variant, :any, default: :full

  data vapid_public_key, :string, default: nil
  data subscriptions, :list, default: []
  data push_supported, :boolean, default: true
  data current_device_subscribed, :boolean, default: false
  data current_endpoint, :string, default: nil

  @doc "What this browser says about notification permission (`granted`, `denied`, `default`), which only the client can know."
  data permission, :string, default: nil

  def update(assigns, socket) do
    # Assign first so __context__ is available
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign(:vapid_public_key, Application.get_env(:ex_nudge, :vapid_public_key))
     |> maybe_load_devices(current_user(assigns) || current_user(socket))}
  end

  # only where they are shown: this renders on every page in its compact form, and a device list nobody is looking at is a query per page load
  defp maybe_load_devices(socket, user) do
    if user && socket.assigns[:vapid_public_key] && socket.assigns[:variant] != :compact,
      do: assign(socket, :subscriptions, WebPush.list_subscriptions(id(user))),
      else: assign(socket, :subscriptions, [])
  end

  # Handle enable push button click - triggers JS to request browser permission
  def handle_event("enable_push", _params, socket) do
    vapid_key = socket.assigns.vapid_public_key
    {:noreply, push_event(socket, "request_push_permission", %{vapid_key: vapid_key})}
  end

  # Handle disable push button click - triggers JS to unsubscribe
  def handle_event("disable_push", _params, socket) do
    {:noreply, push_event(socket, "request_push_disable", %{})}
  end

  @doc """
  What this browser holds, reported on mount, and the chance to make the two agree.

  The browser is the truth about whether this device can receive anything, so a subscription it has that we have no row for is stored as it stands: that happens when an earlier registration never reached us, or a failed send pruned our row while the browser kept its subscription. Storing it is idempotent, since the same endpoint for the same person changes nothing, which matters because writing here re-renders the panel and re-mounts the hook.

  The reverse (we have a row, the browser has nothing) is not acted on: nothing here says *which* of this person's devices this browser was, and removing the wrong one would unsubscribe another. Such a row is deactivated by its next failed send, which is what the health column in the device list is for.

  `permission` is kept as its own state because `denied` and "never asked" are different things to say: a blocked origin cannot be re-prompted, so offering a toggle there would be offering something that cannot work.
  """
  def handle_event("check_subscription", params, socket) do
    user = current_user(socket.assigns)
    subscription = params["subscription"]
    endpoint = e(subscription, "endpoint", nil)

    if user && is_map(subscription) do
      WebPush.subscribe(id(user), subscription)
      |> debug("reconciled what this browser holds with what we had stored")
    end

    {:noreply,
     socket
     |> assign(:current_device_subscribed, not is_nil(endpoint))
     |> assign(:current_endpoint, endpoint)
     |> assign(:permission, params["permission"])
     |> maybe_load_devices(user)}
  end

  # Handle subscription data received from JS hook after browser grants permission
  def handle_event("push_subscription_created", %{"subscription" => subscription_data}, socket) do
    user = current_user(socket.assigns)

    if user do
      user_id = id(user)

      case WebPush.subscribe(user_id, subscription_data) do
        {:ok, subscription} ->
          {level, message} = confirm_by_pushing(subscription, user_id)

          {:noreply,
           socket
           |> maybe_load_devices(user)
           |> assign(:current_device_subscribed, true)
           |> assign_flash(level, message)}

        {:error, changeset} ->
          # a changeset's own words are about our columns, so they go to the log while the screen says what happened and what to try
          error(changeset, "Could not store a push subscription the browser created")

          {:noreply,
           assign_flash(
             socket,
             :error,
             l("Could not turn on notifications for this device. Please try again.")
           )}
      end
    else
      {:noreply,
       assign_flash(socket, :error, l("You must be logged in to enable push notifications"))}
    end
  end

  @doc """
  Turns push off for whoever asked, on the browser they asked from.

  Their subscription, not the device: a browser can be signed into several accounts, and deleting the device row would silently unsubscribe the others. `WebPush.unsubscribe/2` removes the row only once nobody is subscribed to it, which is also the only moment the browser's own subscription is worth dropping.
  """
  def handle_event("push_subscription_disabled", %{"endpoint" => endpoint}, socket) do
    user = current_user(socket.assigns)

    case user && WebPush.unsubscribe(id(user), endpoint) do
      {:ok, who_is_left} ->
        {:noreply,
         socket
         |> maybe_load_devices(user)
         |> assign(:current_device_subscribed, false)
         # the browser's own subscription goes only once nobody is using it, since it is shared
         |> then(fn socket ->
           if who_is_left == :last_one,
             do: push_event(socket, "push_unsubscribe", %{endpoint: endpoint}),
             else: socket
         end)
         |> assign_flash(:info, l("Push notifications turned off for this device"))}

      _ ->
        {:noreply,
         socket
         |> assign(:current_device_subscribed, false)
         |> assign_flash(:info, l("Push notifications disabled"))}
    end
  end

  @doc """
  Says what a failed subscribe means, in terms of what to do about it.

  A browser's own message is written for whoever wrote the browser: `AbortError` is what Firefox raises when it cannot reach a push service, and "AbortError" tells the person nothing they can act on. The technical detail (browser, worker state, protocol) still goes to the console for a bug report; what reaches the screen is the thing worth trying.
  """
  def handle_event("push_subscription_error", %{"error" => error} = params, socket) do
    {:noreply, assign_flash(socket, :error, subscribe_guidance(params["name"], error))}
  end

  defp subscribe_guidance("AbortError", _message) do
    l(
      "Your browser could not reach a push notification service. That usually means this site is not served over HTTPS with a valid certificate, or the network is blocking the connection: another network, or a private window, is worth trying."
    )
  end

  defp subscribe_guidance(name, _message)
       when name in ["NotAllowedError", "PermissionDeniedError"] do
    l(
      "Your browser blocked notifications for this site. You can change that in its site settings."
    )
  end

  defp subscribe_guidance(_name, message) do
    l("Could not turn on notifications: %{error}", error: message)
  end

  # removes this person's subscription to the device, leaving the device for anyone else who uses it
  def handle_event("remove_device", %{"id" => push_device_id}, socket) do
    user = current_user(socket.assigns)

    case UserPushSubscription.unsubscribe(id(user), push_device_id) do
      {:ok, _} ->
        socket = maybe_load_devices(socket, user)
        current_endpoint = socket.assigns[:current_endpoint]

        # removing the device somebody is reading this on is allowed, so the toggle has to follow what is left rather than assume
        still_subscribed? =
          not is_nil(current_endpoint) and
            Enum.any?(socket.assigns[:subscriptions], &is_current_device?(&1, current_endpoint))

        {:noreply,
         socket
         |> assign(:current_device_subscribed, still_subscribed?)
         |> assign_flash(:info, l("Device removed"))}

      {:error, :not_found} ->
        # already gone, most likely removed from another tab or device, so the list is what is out of date rather than anything being wrong
        {:noreply,
         socket
         |> maybe_load_devices(user)
         |> assign_flash(:info, l("That device was already removed"))}

      other ->
        error(other, "Could not remove a push device")

        {:noreply,
         assign_flash(socket, :error, l("Could not remove that device. Please try again."))}
    end
  end

  # Handle push not supported
  def handle_event("push_not_supported", _params, socket) do
    {:noreply, assign(socket, :push_supported, false)}
  end

  # the confirmation IS a push, so turning it on proves the whole chain at the moment somebody cares, through the same channel a real notification uses. It also surfaces the layer browser permission does not cover: an operating system can suppress a browser's notifications entirely (macOS asks per browser), so permission can be granted and nothing ever appear
  defp confirm_by_pushing(%{push_device_id: push_device_id}, user_id) do
    with {:ok, target} <- WebPush.target(push_device_id, user_id),
         :ok <-
           WebPush.deliver(target, %{
             title: l("Notifications are working"),
             body: l("This is what a notification from here looks like.")
           }) do
      {:info,
       l(
         "Notifications are on. You should see a test notification now: if you don't, check whether your system and browser settings allow notifications from here."
       )}
    else
      other ->
        error(other, "Subscribed, but the push service would not take a test notification")

        {:error,
         l(
           "Notifications are on, but a test notification could not seem to reach this device. Ignore this if the notification did arrive, or check your system and browser settings if it didn't."
         )}
    end
  end

  @doc false
  def is_current_device?(sub, current_endpoint) do
    device = sub.push_device
    device && device.address == current_endpoint
  end
end
