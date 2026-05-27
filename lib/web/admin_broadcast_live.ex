defmodule Bonfire.Notify.AdminBroadcastLive do
  use Bonfire.UI.Common.Web, :stateless_component
  use Bonfire.Common.Settings

  declare_settings_component(l("Make an announcement"),
    icon: "ph:megaphone-duotone",
    description:
      l(
        "Write an announcement to send to all local users, or to custom circle(s). It will appear in their notifications feed and trigger push notifications where enabled."
      ),
    scope: :instance
  )

  prop scope, :any, default: :instance
end
