defmodule Bonfire.Notify.Migration do
  @moduledoc false
  use Ecto.Migration
  import Pointers.Migration

  def up do
    create table(:bonfire_web_push_subscription, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # add :user_id, references(Bonfire.Data.Identity.User, on_delete: :nothing, type: :binary_id), null: false
      add(:user_id, :binary, null: false)

      add(:digest, :text, null: false)
      add(:data, :text, null: false)

      timestamps()
    end

    create(unique_index(:bonfire_web_push_subscription, [:user_id, :digest]))

    execute("""
    CREATE TYPE notification_event AS ENUM (
      'CREATED',
      'REPLIED',
      'TEST',
      'MESSAGE'
    )
    """)

    create table(:bonfire_notify, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # add :user_id, references(:users, on_delete: :nothing, type: :binary), null: false
      add(:user_id, :binary, null: false)

      add(:topic, :text, null: false)
      add(:state_dismissed, :boolean, null: false, default: false)
      add(:event_type, :notification_event, null: false)
      add(:data, :map)

      timestamps()
    end
  end

  def down do
    drop(table(:bonfire_web_push_subscription))

    drop(table(:bonfire_notify))

    execute("DROP TYPE notification_event")
    execute("DROP TYPE notification_state")
  end
end
