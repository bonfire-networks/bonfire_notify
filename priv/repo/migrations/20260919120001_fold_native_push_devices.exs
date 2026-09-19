defmodule Bonfire.Notify.Repo.Migrations.FoldNativePushDevices do
  @moduledoc """
  Folds native devices into the merged table and then drops theirs.

  The fold itself is `Bonfire.Notify.DataMigrations.FoldNativeDevices`, which is where it can be tested.

  The drop is safe on the next line because the runner is synchronous: `async: false` means `run/1` returns once the batches are done. It is only reasonable at this size, a row per phone per account. A background fold would be marked done the moment it started, so a drop here would delete rows it had not copied yet, and that version would need two releases instead.

  Nothing to do on a database created after the merge: there is no native table to find.
  """
  use Ecto.Migration

  alias Bonfire.Notify.DataMigrations.FoldNativeDevices
  alias EctoSparkles.DataMigration

  # the fold sleeps between batches and does its own writes, so it must not hold a migration transaction open
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    if table_exists?(FoldNativeDevices.table()) do
      DataMigration.Runner.run(FoldNativeDevices)

      drop_if_exists(table(FoldNativeDevices.table()))
    end
  end

  # one way: the merged rows are the only copy now, and recreating an empty table would claim otherwise
  def down, do: :ok

  defp table_exists?(name) do
    %{rows: [[exists?]]} =
      repo().query!(
        """
        SELECT EXISTS (
          SELECT FROM information_schema.tables
          WHERE table_schema = current_schema() AND table_name = $1
        )
        """,
        [name]
      )

    exists?
  end
end
