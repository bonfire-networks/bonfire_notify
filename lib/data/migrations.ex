defmodule Bonfire.Notify.Migrations do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration

  def up do
    create table(:bonfire_notify_web_push_subscription, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, :binary, null: false)
      add(:endpoint, :text, null: false)
      add(:auth_key, :text, null: false)
      add(:p256dh_key, :text, null: false)

      # Tracking fields
      add(:active, :boolean, default: true, null: false)
      add(:platform, :string)
      add(:user_agent, :text)
      add(:device_name, :string)
      add(:last_used_at, :utc_datetime)
      add(:last_status, :string)
      add(:last_error, :text)
    end

    create(unique_index(:bonfire_notify_web_push_subscription, [:endpoint]))
    create(index(:bonfire_notify_web_push_subscription, [:user_id]))
    create(index(:bonfire_notify_web_push_subscription, [:active]))

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
    drop(table(:bonfire_notify_web_push_subscription))
    execute("DROP TYPE notification_event")
  end
end
