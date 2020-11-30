defmodule Bonfire.Notifications do
  @moduledoc false

  use Application
  require Logger

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Bonfire.Notifications.Registry},
      Bonfire.Notifications.WebPush
    ]

    opts = [strategy: :one_for_one, name: Bonfire.Notifications.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
