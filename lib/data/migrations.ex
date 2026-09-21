defmodule Bonfire.Notify.Migrations do
  @moduledoc """
  What a fresh install needs: one device table, and the per-user links to it.

  An install that predates the merge got there the long way, through the dated migrations that created a table per transport and then folded them together. This creates the result directly, so a new database never builds the old shape only to have it renamed.
  """
  use Ecto.Migration

  def up do
    require Bonfire.Notify.PushDevice.Migration
    Bonfire.Notify.PushDevice.Migration.migrate_push_device(:up)

    require Bonfire.Notify.UserPushSubscription.Migration
    Bonfire.Notify.UserPushSubscription.Migration.migrate_user_push_subscription(:up)
  end

  def down do
    require Bonfire.Notify.UserPushSubscription.Migration
    Bonfire.Notify.UserPushSubscription.Migration.migrate_user_push_subscription(:down)

    require Bonfire.Notify.PushDevice.Migration
    Bonfire.Notify.PushDevice.Migration.migrate_push_device(:down)
  end
end
