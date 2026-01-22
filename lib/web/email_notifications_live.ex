defmodule Bonfire.Notify.Settings.EmailNotificationsLive do
  use Bonfire.UI.Common.Web, :stateless_component

  declare_settings_component(l("Email Notifications"),
    icon: "ph:device-mobile",
    description: l("What activities to receive email notifications for")
  )

  prop scope, :any, default: nil
  prop event_name, :any, default: nil
  prop event_target, :any, default: nil
end
