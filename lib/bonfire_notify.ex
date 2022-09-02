defmodule Bonfire.Notify do
  @moduledoc false

  use Application
  import Untangle

  def start(_type, _args) do
    if enabled() do

      children = [
        {Registry, keys: :unique, name: Bonfire.Notify.Registry},
        Bonfire.Notify.WebPush
      ]

      opts = [strategy: :one_for_one, name: Bonfire.Notify.Supervisor]
      Supervisor.start_link(children, opts)

    else
      warn("""
      Web Push not enabled because a VAPID key pair was not found. Please run:

          mix web_push.gen.keypair

      and add the resulting output to your configuration file or environment.
      """)

      children = []
      opts = [strategy: :one_for_one]
      Supervisor.start_link(children, opts)
    end

  end

  def vapid_config do
    Application.get_env(:web_push_encryption, :vapid_details, [])
  end

  def enabled do
    case vapid_config() do
      [] -> false
      list when is_list(list) ->
        if list[:private_key] !="" and list[:public_key] !="" do
          true
        else
          false
        end
      _ -> false
    end
  end

end
