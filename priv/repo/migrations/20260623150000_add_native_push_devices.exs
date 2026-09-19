defmodule Bonfire.Notify.Repo.Migrations.AddNativePushDevices do
  @moduledoc """
  Created `bonfire_notify_native_push_device`, which no longer exists: native devices are rows in `bonfire_notify_push_device` alongside web ones, and `20260919...MergePushDevices` is what folded them in.

  Nothing left to do here. Every database that has the old table already ran this, and a migration already recorded as run is never run again, so emptying it only affects databases that have yet to be created. Those get the merged table from `Bonfire.Notify.Migrations.up/0` and must not build the old one first.
  """
  use Ecto.Migration

  def up, do: :ok

  def down, do: :ok
end
