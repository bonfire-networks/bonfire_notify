defmodule Bonfire.Notify.RuntimeConfig do
  @moduledoc "Config and helpers for this library"

  import Untangle
  require Bonfire.Common.Config

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @yes? ~w(true yes 1)
  @no? ~w(false no 0)

  def config do
    import Config

    # config :bonfire_notify,
    #   modularity: :disabled
    config :bonfire_notify, modularity: nil

    # Web push
    config :bonfire_notify, Bonfire.Notify.WebPush,
      # adapter: Bonfire.Notify.WebPush.HttpAdapter,
      retry_timeout: 1000,
      max_attempts: 5

    # Configure browser push notifications

    # config :web_push_encryption, :vapid_details,
    #   subject: System.get_env("WEB_PUSH_SUBJECT", "https://bonfire.cafe"),
    #   public_key: System.get_env("WEB_PUSH_PUBLIC_KEY"),
    #   private_key: System.get_env("WEB_PUSH_PRIVATE_KEY")

    config :ex_nudge,
      # generate keys using `Bonfire.Notify.WebPush.generate_keys_env()`
      # TODO: generate on first use if not set, and store with Bonfire.Common.Settings
      vapid_public_key: System.get_env("WEB_PUSH_PUBLIC_KEY"),
      vapid_private_key: System.get_env("WEB_PUSH_PRIVATE_KEY"),
      vapid_subject: System.get_env("WEB_PUSH_SUBJECT", "https://bonfire.cafe")
  end
end
