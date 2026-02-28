defmodule Bonfire.Notify.Repo.Migrations.ReInitNotify do
  @moduledoc """
  Drops and recreates notify tables with the new split schema:
  - bonfire_notify_web_push_subscription (device-level, no user_id)
  - bonfire_notify_user_push_subscription (Needle mixin linking users to push subscriptions)
  """
  use Ecto.Migration

  def up do
    # Clean up old schema
    drop_if_exists(table(:bonfire_notify_user_push_subscription))
    drop_if_exists(table(:bonfire_notify_web_push_subscription))
    execute("DROP TYPE IF EXISTS notification_event")

    # Recreate with new schema
    Bonfire.Notify.Migrations.up()
  end

  def down do
    Bonfire.Notify.Migrations.down()
  end
end
