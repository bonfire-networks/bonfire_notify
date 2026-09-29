defmodule Bonfire.Notify.Bells do
  @moduledoc """
  Bells: someone asking to be notified about what happens on a person, a group or a thread (`Bonfire.Notify.Data.Bell`).

  Off until the person enables one: following or joining never does. What a bell covers comes from what it is on: a person's or group's new posts, or a thread's replies. The fan-out asks `subscribers/2` on every publish, so the post's own activity lands in each subscriber's notifications, and everything after that (preferences, delivery, seen state) is what any notification gets.

  Edges are built and deleted through `Bonfire.Social.Edges`, asked rather than called since this extension does not depend on `bonfire_social`, and without it there is nothing to be notified about.
  """
  use Bonfire.Common.E
  use Bonfire.Common.Repo
  use Bonfire.Common.Settings
  import Ecto.Query
  import Untangle

  alias Bonfire.Common.Types
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Notify.Data.Bell

  @doc "Enables this person's bell on a person, group or thread. `{:ok, bell}`, also when it was already enabled."
  def enable(subscriber, object) do
    with %Ecto.Changeset{} = changeset <-
           Bonfire.Common.Utils.maybe_apply(
             Bonfire.Social.Edges,
             :changeset_base,
             [Bell, subscriber, object, []],
             fallback_return: nil
           ),
         {:ok, bell} <- changeset |> unique_on_edge() |> repo().insert() do
      {:ok, bell}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        # the unique index on (subscriber, object, kind) is what answers "already enabled", in the same round trip as the insert
        if already_enabled?(changeset),
          do: {:ok, :already_enabled},
          else: error(changeset, "Could not enable the bell")

      nil ->
        error(object, "Cannot enable a bell without the Bonfire Social extension enabled")
    end
  end

  @doc """
  The bell a new post or comment rings for its author, as a changeset to insert along with it, so they hear about the replies below it even when they're not mentioned, and can turn that off for this post with its bell.

  `nil` for an author who isn't local, when their `[:notifications, :notify_any_replies]` switch is off, or when one of their bells is already on a post above it (`ancestor_ids`), since that one covers the replies below this one too.
  """
  def enable_thread_notifications_changeset(author, object_id, ancestor_ids \\ []) do
    cond do
      # only people here have notifications to be told in: a post arriving from elsewhere enables nothing
      not Bonfire.Common.Utils.maybe_apply(
        Bonfire.Social,
        :is_local?,
        [author, [preload_if_needed: true]],
        fallback_return: false
      ) ->
        nil

      not Settings.get([:notifications, :notify_any_replies], true, current_user: author) ->
        nil

      enabled_in_thread_above?(author, ancestor_ids) ->
        nil

      true ->
        case Bonfire.Common.Utils.maybe_apply(
               Bonfire.Social.Edges,
               :changeset_base,
               [Bell, author, object_id, []],
               fallback_return: nil
             ) do
          %Ecto.Changeset{} = changeset ->
            changeset |> unique_on_edge() |> Map.put(:action, :insert)

          _ ->
            nil
        end
    end
  end

  # whether this person has a bell on any of these posts
  defp enabled_in_thread_above?(author, ancestor_ids) do
    case ancestor_ids |> List.wrap() |> Enum.map(&Types.uid/1) |> Enum.reject(&is_nil/1) do
      [] ->
        false

      ancestor_ids ->
        from(e in Edge,
          where:
            e.subject_id == ^Types.uid(author) and e.table_id == ^bell_table_id() and
              e.object_id in ^ancestor_ids
        )
        |> repo().exists?()
    end
  end

  @doc "Disables this person's bell on a person, group or thread, if there was one."
  def disable(subscriber, object) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Edges,
      :delete_by_both,
      [subscriber, Bell, object],
      fallback_return: {:ok, 0}
    )
  end

  @doc """
  How many notifications this person has on: `:all` of them, or only those on what they `:followed` (people, groups, and posts they didn't write), leaving out the ones their own posts and comments enabled. For the confirmations of the two unsubscribe buttons. One query.
  """
  def count(subscriber, which \\ :all),
    do: which |> bells_of(subscriber) |> repo().aggregate(:count)

  @doc """
  Turns off `:all` of this person's notifications, or only those on what they `:followed`, leaving their own posts' on. Deletes the edges, as `disable/2` does for one, in one query. `{:ok, count}`.
  """
  def disable_all(subscriber, which \\ :all) do
    ids = which |> bells_of(subscriber) |> select([edge: e], e.id)

    {count, _} = from(e in Edge, where: e.id in subquery(ids)) |> repo().delete_all()
    {:ok, count}
  end

  defp bells_of(:all, subscriber) do
    from(e in Edge,
      as: :edge,
      where: e.subject_id == ^Types.uid(subscriber) and e.table_id == ^bell_table_id()
    )
  end

  # people and groups have no `created` row, so they count as followed
  defp bells_of(:followed, subscriber) do
    from([edge: e] in bells_of(:all, subscriber),
      left_join: c in Bonfire.Data.Social.Created,
      on: c.id == e.object_id,
      where: is_nil(c.creator_id) or c.creator_id != ^Types.uid(subscriber)
    )
  end

  @doc "Which of these objects this person has notifications on for, in one query: for a list of relationships (a Mastodon client's `notifying`)."
  def enabled_ids(subscriber, object_ids) do
    case object_ids |> List.wrap() |> Enum.map(&Types.uid/1) |> Enum.reject(&is_nil/1) do
      [] ->
        []

      object_ids ->
        from([edge: e] in bells_of(:all, subscriber),
          where: e.object_id in ^object_ids,
          select: e.object_id
        )
        |> repo().all()
    end
  end

  @doc "Whether this person has a bell enabled on a person, group or thread."
  # no boundary check: a bell has no ACL of its own, and whose it is is the question asked
  def enabled?(subscriber, object) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Edges,
      :exists?,
      [__MODULE__, subscriber, object, [skip_boundary_check: true]],
      fallback_return: false
    )
  end

  @doc "Bells as an edge query, the way `Bonfire.Social.Edges` asks an edge's context for one."
  def query(filters, opts) do
    Bonfire.Common.Utils.maybe_apply(Bonfire.Social.Edges, :query_parent, [Bell, filters, opts])
  end

  @doc """
  Whoever has a bell on any of these objects, except the author of what is being published and anyone deleted, each with their character loaded. Any subject with a character, not only a user: whatever has a notifications feed can have a bell. One query, through the bells' own index.

  Subjects rather than feed ids, shaped like the others the fan-out notifies (`Feeds.fan_out_feeds/6`'s `notify_users`), so it takes each notifications feed from the loaded character and hands them on to delivery.

  Which objects is the caller's to decide, since it knows what is being published: a new post's author and groups, or a reply's thread root.

  With `authorship: true`, each comes as `{subject, wrote_it?}`: whether the post their notifications are on (any of them, where there are several) is one they wrote. For a reply, that is what tells a reply below something they wrote from one in a discussion they follow (`Activities.experienced_as/3`'s `wrote_above:`). Same query, with one more join.
  """
  def subscribers(object_ids, author, opts \\ []) do
    case object_ids |> List.wrap() |> Enum.map(&Types.uid/1) |> Enum.reject(&is_nil/1) do
      [] ->
        []

      object_ids ->
        # from the subscriber's pointer, which is what a deleted one is marked on, with the character whose notifications feed they get
        query =
          from(p in Needle.Pointer,
            join: e in Edge,
            on: e.subject_id == p.id,
            join: c in assoc(p, :character),
            where:
              e.table_id == ^bell_table_id() and e.object_id in ^object_ids and
                e.subject_id != ^Types.uid(author) and is_nil(p.deleted_at),
            distinct: p.id
          )

        if opts[:authorship] do
          # one row per subscriber, the one on a post they wrote first where there is one
          from([p, e, c] in query,
            left_join: cr in Bonfire.Data.Social.Created,
            on: cr.id == e.object_id,
            order_by: [desc: fragment("coalesce(? = ?, false)", cr.creator_id, p.id)],
            select: {p, c, fragment("coalesce(? = ?, false)", cr.creator_id, p.id)}
          )
          |> repo().all()
          |> Enum.map(fn {p, c, wrote_it?} -> {Map.put(p, :character, c), wrote_it?} end)
        else
          query
          |> preload([p, e, c], character: c)
          |> repo().all()
        end
    end
  end

  defp bell_table_id, do: Bell.__pointers__(:table_id)

  # a second bell on the same thing breaks the per-type unique index on the nested edge, but `Edges.put_edge_assoc/4` declares that index on the bell's own changeset and `Edge.changeset/2` declares it under its default name, so without this Ecto raises rather than returning the error that says "already enabled"
  defp unique_on_edge(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.update_change(
      changeset,
      :edge,
      &Ecto.Changeset.unique_constraint(&1, [:subject_id, :object_id, :table_id],
        name: "bonfire_data_edges_edge_#{Bell.__schema__(:source)}_unique_index"
      )
    )
  end

  # the error is on the nested edge, where `Edges.put_edge_assoc/4` declared the unique constraint
  defp already_enabled?(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {_message, opts} -> opts[:constraint] end)
    |> constraints()
    |> Enum.member?(:unique)
  end

  defp constraints(errors) when is_map(errors),
    do: Enum.flat_map(errors, fn {_field, nested} -> constraints(nested) end)

  defp constraints(errors) when is_list(errors), do: Enum.flat_map(errors, &constraints/1)
  defp constraints(constraint), do: [constraint]
end
