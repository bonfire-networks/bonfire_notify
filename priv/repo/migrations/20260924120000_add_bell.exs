defmodule Bonfire.Notify.Repo.Migrations.AddBell do
  @moduledoc """
  The bells people ring on a person, a group or a thread to be notified about what happens there (`Bonfire.Notify.Data.Bell`), with their unique index and the index every publish asks them through.

  Here only, not also in `Bonfire.Notify.Migrations.up/0`: a new database runs that (through the reinit migration) and then every dated migration after it, this one included, so creating the table in both would create it twice.
  """
  use Ecto.Migration
  require Bonfire.Notify.Data.Bell.Migration

  def up, do: Bonfire.Notify.Data.Bell.Migration.migrate_bell(:up)
  def down, do: Bonfire.Notify.Data.Bell.Migration.migrate_bell(:down)
end
