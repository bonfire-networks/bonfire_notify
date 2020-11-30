use Mix.Config

# Web push
config :bonfire_notifications, Bonfire.Notifications.WebPush,
  adapter: Bonfire.Notifications.WebPush.HttpAdapter,
  retry_timeout: 1000,
  max_attempts: 5

# Configure browser push notifications
config :web_push_encryption, :vapid_details,
  subject: "https://levelteams.com",
  public_key: System.get_env("WEB_PUSH_PUBLIC_KEY"),
  private_key: System.get_env("WEB_PUSH_PRIVATE_KEY")
