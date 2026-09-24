defmodule Bonfire.Notify.Settings.NotificationPreferencesLive do
  @moduledoc """
  Puts the notification preferences panel on this extension's settings page.

  Placement, not delegation: the panel itself is `Bonfire.UI.Social.NotificationPreferencesLive`, because most of what it holds configures the notifications *feed* (which categories appear in it, how it is displayed) and that has to keep working on an instance with this extension disabled. Settings sections are grouped by the module's own app, though, so something here has to be what declares it, or notification preferences would sit under the social UI while push and email sit here.

  Rendered through `maybe_component` for the same reason in reverse: this extension does not depend on `bonfire_ui_social` either, so a flavour without it gets no section rather than a crash.
  """
  use Bonfire.UI.Common.Web, :stateless_component

  declare_settings_component(l("Notifications"),
    icon: "ph:bell-ringing",
    description: l("What you are notified about, and how it reaches you")
  )

  @doc "Which settings scope this is being shown for."
  prop scope, :any, default: nil

  def render(assigns) do
    ~F"""
    {!-- for instance admins: their own digest, now, to check how it looks without waiting for the schedule --}
    <button
      :if={Bonfire.Me.Accounts.is_admin?(current_account(@__context__))}
      id="send_test_digest"
      type="button"
      phx-click="Bonfire.Notify:send_test_digest"
      class="btn btn-sm btn-outline mt-4"
    >{l("Send me a test digest")}</button>
    
    {#case maybe_component(
        Bonfire.UI.Social.NotificationPreferencesLive,
        @__context__
      )}
      {#match nil}
        <StatefulComponent
          module={maybe_component(Bonfire.Notify.Settings.PushNotificationsLive, @__context__)}
          id="notification-push-devices"
        />
      {#match component}
        <StatelessComponent module={component} scope={@scope} />
    {/case}
    """
  end
end
