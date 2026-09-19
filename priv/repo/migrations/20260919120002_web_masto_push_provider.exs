defmodule Bonfire.Notify.Repo.Migrations.WebMastoPushProvider do
  @moduledoc """
  Lets a Web Push endpoint say which client registered it, by adding `web_masto` beside `web`.

  Only the check constraint has to change: it says the RFC 8291 encryption keys belong to Web Push rows, and it named one provider when there was one. `Bonfire.Notify.PushDevice.Migration.add_web_keys_constraint/0` spells that set from the list the channel claims, so re-running it is what brings an existing database in line, and it drops the old constraint first so doing so twice is harmless.
  """
  use Ecto.Migration

  def up do
    require Bonfire.Notify.PushDevice.Migration
    Bonfire.Notify.PushDevice.Migration.add_web_keys_constraint()
  end

  # the constraint is the current rule either way, and an older one would refuse rows that are already there
  def down, do: :ok
end
