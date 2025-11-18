defmodule Bonfire.Notify.PushNotifyLive do
  use Bonfire.UI.Common.Web, :stateless_component

  # Note: All event handling is done by parent LiveView using Bonfire.Notify.LiveHandler
  # This component is stateless and just renders the UI

  prop vapid_public_key, :string, required: true
  prop is_pwa, :boolean, default: false
  prop subscriptions, :list, default: []
  prop subscription_size, :integer, default: 0

  prop event_target, :any, required: true

  def render(assigns) do
    ~H"""
    <div
      :if={@vapid_public_key}
      id="push-notifications-component"
      class="space-y-6"
      phx-hook="PushNotificationHook"
    >
      <div>
        <button
          :if={!@is_pwa}
          id="install-button"
          type="button"
          class="btn btn-success btn-sm"
          style="display: none;"
        >
          {l("Install app")}
        </button>
      </div>

      <div class="alert alert-info">
        <div class="flex items-center justify-between w-full">
          <div>
            <h3 class="font-medium">
              {l("Push Notifications")}
              <div id="status-indicator" class="badge badge-ghost w-3 h-3 rounded-full p-0"></div>
            </h3>
            <p class="text-sm opacity-70">{l("Get alerts on your subscriptions")}</p>

            <div class="flex flex-wrap gap-2">
              <button
                id="subscribe-btn"
                type="button"
                class="btn btn-primary btn-sm"
              >
                {l("Enable Notifications")}
              </button>

              <button
                phx-click="Bonfire.Notify:broadcast_test_notification"
                phx-target={@event_target}
                type="button"
                class="btn btn-success btn-sm"
              >
                {l("Broadcast Test")}
              </button>

              <button
                phx-click="Bonfire.Notify:refresh_subscriptions"
                phx-target={@event_target}
                type="button"
                class="btn btn-ghost btn-sm"
              >
                {l("Refresh")}
              </button>
            </div>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300">
        <div class="card-body p-0">
          <div class="px-4 py-3 bg-base-200">
            <h4 class="font-medium text-sm">
              {l("Registered subscriptions")} ({@subscription_size})
            </h4>
          </div>

          <div class="divide-y divide-base-300">
            <%= for sub <- @subscriptions do %>
              <div id={"subscription-#{sub.id}"} class="px-4 py-3 flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <span class="text-sm font-mono">{sub.id}</span>
                </div>

                <div class="flex gap-2">
                  <button
                    phx-click="Bonfire.Notify:test_notification"
                    phx-value-subscription_id={sub.id}
                    phx-target={@event_target}
                    class="btn btn-xs btn-info"
                  >
                    {l("Test")}
                  </button>

                  <button
                    phx-click="Bonfire.Notify:remove_subscription"
                    phx-value-subscription_id={sub.id}
                    phx-target={@event_target}
                    data-confirm={l("Remove this device?")}
                    class="btn btn-xs btn-error"
                  >
                    {l("Remove")}
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <input type="hidden" id="vapid-public-key" value={@vapid_public_key} />
    </div>
    """
  end
end
