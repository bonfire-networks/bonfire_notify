defmodule Bonfire.Notify.Data.Bell do
  @moduledoc """
  A bell someone rang on a person, a group or a thread: "notify me about what happens there".

  Stored the way a request is (`Bonfire.Data.Social.Request`): this row says it is a bell, and the `Edge` sharing its id says whose it is (the subject, who enabled it) and on what (the object). A plain bell carries this schema's own `table_id` on its edge, and what it covers comes from its object: new posts for a person or group, replies for a thread root. A later kind of bell (a person's boosts, say) would carry that verb in the edge's `table_id` instead, beside the plain one.

  No fields yet. It is a pointable rather than a virtual schema so that per-bell choices (which channels, say) can be added as a column later.
  """
  use Needle.Pointable,
    otp_app: :bonfire_notify,
    table_id: "7BE11R1NGSN0T1FYMEPR0MPT1Y",
    source: "bonfire_notify_bell"

  alias Bonfire.Data.Edges.Edge
  alias Ecto.Changeset

  pointable_schema do
    has_one(:edge, Edge, foreign_key: :id)
  end

  def changeset(bell \\ %__MODULE__{}, params), do: Changeset.cast(bell, params, [:id])
end

defmodule Bonfire.Notify.Data.Bell.Migration do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration
  alias Bonfire.Notify.Data.Bell

  @edge_table "bonfire_data_edges_edge"

  defp make_bell_table(exprs) do
    quote do
      require Needle.Migration

      Needle.Migration.create_pointable_table Bonfire.Notify.Data.Bell do
        (unquote_splicing(exprs))
      end
    end
  end

  defmacro create_bell_table(), do: make_bell_table([])
  defmacro create_bell_table(do: body), do: make_bell_table(body)

  def drop_bell_table(), do: drop_pointable_table(Bell)

  @doc "One bell per person, object and kind, as for any edge type that should not repeat."
  def migrate_bell_unique_index(dir \\ direction()),
    do: Bonfire.Data.Edges.Edge.Migration.migrate_type_unique_index(dir, Bell)

  @doc """
  Who rang a bell on this object, which is what every publish asks. The edge table's own `object_id` index would also hold every follow, like and boost of that object, so a popular person would be a long scan: this one holds bells only.
  """
  def migrate_bell_object_index(dir \\ direction())

  def migrate_bell_object_index(:up) do
    create_if_not_exists(
      index(@edge_table, [:object_id],
        where: "table_id = '#{bell_table_uuid()}'",
        name: "#{@edge_table}_bonfire_notify_bell_object_index"
      )
    )
  end

  def migrate_bell_object_index(:down) do
    drop_if_exists(
      index(@edge_table, [:object_id], name: "#{@edge_table}_bonfire_notify_bell_object_index")
    )
  end

  # as `Edge.Migration.migrate_type_unique_index/2` writes a table id into a partial index
  defp bell_table_uuid do
    Bell.__pointers__(:table_id)
    |> Needle.ULID.dump()
    |> elem(1)
    |> Ecto.UUID.cast!()
  end

  defp mb(:up) do
    quote do
      unquote(make_bell_table([]))
      Bonfire.Notify.Data.Bell.Migration.migrate_bell_unique_index(:up)
      Bonfire.Notify.Data.Bell.Migration.migrate_bell_object_index(:up)
    end
  end

  defp mb(:down) do
    quote do
      Bonfire.Notify.Data.Bell.Migration.migrate_bell_object_index(:down)
      Bonfire.Notify.Data.Bell.Migration.migrate_bell_unique_index(:down)
      Bonfire.Notify.Data.Bell.Migration.drop_bell_table()
    end
  end

  defmacro migrate_bell() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(mb(:up)),
        else: unquote(mb(:down))
    end
  end

  defmacro migrate_bell(dir), do: mb(dir)
end
