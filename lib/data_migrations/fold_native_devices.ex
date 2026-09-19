defmodule Bonfire.Notify.DataMigrations.FoldNativeDevices do
  @moduledoc """
  Folds the rows of the old `bonfire_notify_native_push_device` table into `bonfire_notify_push_device`, giving each one the per-user subscription that web devices always had.

  Written through the same functions a native client registers through, so the rows this produces are the rows registering produces. That also means it fixes what it copies: the old table let one device token belong to one `user_id`, so a second account registering the same phone took it from the first. Each old row becomes a device plus one subscription, and a device two accounts share ends up with two.

  Each row is deleted once it has been folded, which is what lets the run resume where it stopped rather than starting over.

  Lives here rather than in the migration so it can be tested.
  """

  import Ecto.Query
  import Untangle

  alias Bonfire.Notify.NativePushDevice
  alias Bonfire.Notify.UserPushSubscription
  alias EctoSparkles.DataMigration

  @table "bonfire_notify_native_push_device"

  @doc "The table this reads from, which no longer has a schema."
  def table, do: @table

  def base_query do
    from(d in @table,
      select: %{
        id: d.id,
        user_id: d.user_id,
        provider: d.provider,
        token: d.token,
        platform: d.platform,
        device_name: d.device_name,
        active: d.active,
        policy: d.policy,
        last_used_at: d.last_used_at,
        last_status: d.last_status,
        last_error: d.last_error
      }
    )
  end

  def config do
    # small by nature (a row per phone per account), and `async: false` so the migration that calls this can drop the table on the next line rather than racing a background task
    %DataMigration.Config{
      batch_size: 100,
      throttle_ms: 100,
      async: false,
      repo: Bonfire.Common.Repo
    }
  end

  def migrate(rows) do
    owners = existing_owners(rows)

    Enum.each(rows, fn row ->
      if MapSet.member?(owners, row.user_id),
        do: fold(row),
        # a subscription needs somebody to belong to, and the mixin's foreign key would raise rather than refuse, taking the whole batch with it. The row goes away with the table
        else: warn(row.user_id, "Native push device belongs to nobody, so leaving it behind")
    end)
  end

  # one query per batch rather than one per row, and the only thing that can make a row unfoldable
  defp existing_owners(rows) do
    ids = rows |> Enum.map(& &1.user_id) |> Enum.uniq()

    from(p in Needle.Pointer, where: p.id in ^ids, select: p.id)
    |> Bonfire.Common.Repo.all()
    |> MapSet.new()
  end

  defp fold(row) do
    with {:ok, device} <- NativePushDevice.find_or_create(device_attrs(row)),
         {:ok, _link} <- UserPushSubscription.upsert(row.user_id, device.id, link_attrs(row)) do
      delete(row.id)
    else
      other ->
        warn(other, "Could not fold native push device #{inspect(row.id)}, so leaving it behind")
    end
  end

  defp device_attrs(row) do
    %{
      provider: row.provider,
      token: row.token,
      # the old column held what the client declared, which is what `device_agent` is for
      platform: row.platform,
      device_name: row.device_name,
      active: row.active,
      last_used_at: row.last_used_at,
      last_status: row.last_status,
      last_error: row.last_error
    }
  end

  # the old table kept an `alerts` map that nothing read, so only the policy carries over
  defp link_attrs(row), do: %{policy: row.policy}

  defp delete(id) do
    from(d in @table, where: d.id == ^id)
    |> Bonfire.Common.Repo.delete_all()
  end
end
