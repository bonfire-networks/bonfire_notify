defmodule Bonfire.Notify.Repo.Migrations.AddMastoPushFields do
  @moduledoc """
  Adds alerts and policy fields for Mastodon-compatible push subscription API.
  Only runs if columns don't already exist (safe for fresh installs that have them in migrations.ex).
  """
  use Ecto.Migration

  def up do
    # Check if columns already exist before adding
    if not column_exists?(:bonfire_notify_web_push_subscription, :alerts) do
      alter table(:bonfire_notify_web_push_subscription) do
        add :alerts, :map, default: %{
          "follow" => true,
          "favourite" => true,
          "reblog" => true,
          "mention" => true,
          "poll" => true,
          "status" => false,
          "update" => false
        }
      end
    end

    if not column_exists?(:bonfire_notify_web_push_subscription, :policy) do
      alter table(:bonfire_notify_web_push_subscription) do
        add :policy, :string, default: "all"
      end
    end
  end

  def down do
    alter table(:bonfire_notify_web_push_subscription) do
      remove_if_exists :alerts, :map
      remove_if_exists :policy, :string
    end
  end

  defp column_exists?(table, column) do
    query = """
    SELECT column_name FROM information_schema.columns
    WHERE table_name = '#{table}' AND column_name = '#{column}'
    """

    case repo().query(query) do
      {:ok, %{num_rows: n}} when n > 0 -> true
      _ -> false
    end
  end
end
