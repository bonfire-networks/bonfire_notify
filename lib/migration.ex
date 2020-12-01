defmodule Bonfire.Notifications.Migration do
  use Ecto.Migration
  import Pointers.Migration


  def change do
    create table(:bonfire_web_push_subscriptions, primary_key: false) do

      add :id, :binary_id, primary_key: true

      # add :user_id, references(Bonfire.Data.Identity.User, on_delete: :nothing, type: :binary_id), null: false
      add :user_id, :binary, null: false

      add :digest, :text, null: false
      add :data, :text, null: false

      timestamps()
    end

    create unique_index(:bonfire_web_push_subscriptions, [:user_id, :digest])

  end

end
