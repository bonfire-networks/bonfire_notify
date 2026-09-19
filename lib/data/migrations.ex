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

    execute("""
    CREATE TYPE notification_event AS ENUM (
      'CREATED',
      'REPLIED',
      'TEST',
      'MESSAGE'
    )
    """)
  end

  def down do
    require Bonfire.Notify.UserPushSubscription.Migration
    Bonfire.Notify.UserPushSubscription.Migration.migrate_user_push_subscription(:down)

    require Bonfire.Notify.PushDevice.Migration
    Bonfire.Notify.PushDevice.Migration.migrate_push_device(:down)

    execute("DROP TYPE notification_event")
  end
end
