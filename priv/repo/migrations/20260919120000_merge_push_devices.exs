defmodule Bonfire.Notify.Repo.Migrations.MergePushDevices do
  @moduledoc """
  Turns `bonfire_notify_web_push_subscription` into `bonfire_notify_push_device`: one table for every device we can reach, whichever transport reaches it.

  Renames rather than copies, because a table and column rename is metadata only. Web rows gain the `provider` the native table always had, `endpoint` and `token` become one `address` under one unique index, and `platform`/`user_agent` become one `device_agent` holding whatever the client said about itself.

  Native rows are folded in by the migration after this one, which then drops their table.

  Nothing to do on a database created after the merge: `Bonfire.Notify.Migrations.up/0` makes the merged table directly, so there is no old table to find here.
  """
  use Ecto.Migration

  @old_table "bonfire_notify_web_push_subscription"
  @table "bonfire_notify_push_device"
  @links "bonfire_notify_user_push_subscription"

  def up do
    if table_exists?(@old_table) do
      rename(table(@old_table), to: table(@table))

      rename(table(@table), :endpoint, to: :address)
      rename(table(@table), :user_agent, to: :device_agent)

      alter table(@table) do
        add(:provider, :string)
      end

      # every row here is a browser, and `platform` was a guess made at subscribe time from the User-Agent we already stored, so it is only worth keeping where there was no header to guess from
      execute("""
      UPDATE #{@table}
      SET provider = 'web',
          device_agent = coalesce(device_agent, platform)
      """)

      alter table(@table) do
        modify(:provider, :string, null: false)
        remove(:platform)

        # the encryption keys were required when every row was a browser. A native gateway carries the payload to itself and has no counterpart for them, so the check constraint below is what requires them of web rows and forbids them on native ones
        modify(:auth_key, :text, null: true)
        modify(:p256dh_key, :text, null: true)
      end

      # one unique index for every transport, replacing unique-on-endpoint here and unique-on-(provider, token_hash) on the native table
      execute("DROP INDEX IF EXISTS #{@old_table}_endpoint_index")
      # renaming a table leaves its indexes under their old names, so this one is recreated rather than left reading as if it belonged to a table that no longer exists
      execute("DROP INDEX IF EXISTS #{@old_table}_active_index")
      create_if_not_exists(unique_index(@table, [:provider, :address]))
      create_if_not_exists(index(@table, [:active]))

      require Bonfire.Notify.PushDevice.Migration
      Bonfire.Notify.PushDevice.Migration.add_web_keys_constraint()

      rename(table(@links), :push_subscription_id, to: :push_device_id)

      alter table(@links) do
        add(:access_token_id, :uuid)
      end

      require Bonfire.Notify.UserPushSubscription.Migration
      Bonfire.Notify.UserPushSubscription.Migration.migrate_access_token_index(:up)
    end
  end

  def down do
    :ok
  end

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
