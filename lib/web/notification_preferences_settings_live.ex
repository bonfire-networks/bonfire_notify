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
        <StatelessComponent module={component} />
    {/case}
    """
  end
end
