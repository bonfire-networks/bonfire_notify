defmodule Bonfire.Notify.Repo.Migrations.AddNativePushDevices do
  @moduledoc false
  use Ecto.Migration

  def up do
    require Bonfire.Notify.NativePushDevice.Migration
    Bonfire.Notify.NativePushDevice.Migration.migrate_native_push_device(:up)
  end

  def down do
    require Bonfire.Notify.NativePushDevice.Migration
    Bonfire.Notify.NativePushDevice.Migration.migrate_native_push_device(:down)
  end
end
