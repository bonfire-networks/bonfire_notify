defmodule Bonfire.Notify.Repo.Migrations.ReInitNotify do
  @moduledoc """
  Drops whatever the first version of this extension left behind, and creates what `Bonfire.Notify.Migrations.up/0` says a fresh install needs: one device table, and the per-user subscriptions to it.

  The drops name tables that no longer exist anywhere in the code. They are here for databases that still had them when this ran, and do nothing on a new one.
  """
  use Ecto.Migration

  def up do
    drop_if_exists(table(:bonfire_notify_user_push_subscription))
    drop_if_exists(table(:bonfire_notify_web_push_subscription))
    execute("DROP TYPE IF EXISTS notification_event")

    Bonfire.Notify.Migrations.up()
  end

  def down do
    Bonfire.Notify.Migrations.down()
  end
end
