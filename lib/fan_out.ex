defmodule Bonfire.Notify.FanOut do
  @moduledoc """
  Deciding who is still worth notifying, once an activity's recipients are known.

  Two things can have changed between publishing and delivering, which is why this is checked in the job rather than at write time: the object's boundary (a grant revoked in between must not be delivered) and whether the person has already seen it (they were looking at the feed while the job
  waited). Both are one query for the whole batch.

  `Seen` is account-keyed, so reading something as one persona counts for all of them, which is deliberate.

  The boundary check is `Boundaries.users_grants_on/3` rather than a per-recipient `can?/3` or `load_pointers/2`, which would be one query each. It reads the same `Summary` view a feed's own filter does (`Boundaries.Queries.query_with_summary/2`), with the same circle expansion and the same negative precedence, so it sees what the reader would see in their feed. Blocks included: hiding or locking an object writes `:cannot_discover`/`:cannot_participate` grants on its ACL, and blocking a person puts them in stereotype circles whose grants are in that view too.
  """
  use Bonfire.Common.Repo
  use Bonfire.Common.E
  import Ecto.Query
  import Untangle

  alias Bonfire.Boundaries
  alias Bonfire.Common.Types
  alias Bonfire.Data.Edges.Edge

  # the schema, since that is what carries the table id an Edge row is keyed by (the context module has none)
  alias Bonfire.Data.Social.Seen

  @doc """
  Notifies everyone an activity reached: resolves them, drops whoever it no longer applies to, and enqueues one delivery per device.

  Runs here and now by default, so whoever caused the notification learns if it fails, and returns `{:ok, %{deliveries: n}}` or an error tuple to report. Callers run it after their transaction commits, which for the Epic is `Bonfire.Social.Acts.LivePush` (it skips itself when the epic has errors, so a failed insert never reaches this).

  `async: true` hands it to `Bonfire.Notify.Worker` instead, which runs this same function inside a job: durable, retried, and capped by the queue rather than competing with requests. That is what an instance-wide broadcast wants, and any caller with no post-commit place to run from.

  Takes the notified feeds and, where the write path already resolved them, the recipients, as `%{feeds: [feed_id], recipients: [%{user_id:, feed:}]}`.
  """
  def notify(activity, notifying, opts \\ [])

  def notify(activity, notifying, opts) do
    if opts[:async] do
      Bonfire.Common.Utils.maybe_apply(
        Bonfire.Notify.Worker,
        :enqueue_fan_out,
        [Types.uid(activity), notifying],
        fallback_return: :skip
      )
    else
      recipients =
        Bonfire.Notify.Recipients.for_job(
          e(notifying, :recipients, []),
          e(notifying, :feeds, []),
          exclude: e(activity, :subject_id, nil) || e(activity, :subject, nil)
        )
        |> still_to_notify(activity)

      recipients
      |> targets(activity)
      |> Bonfire.Notify.Deliveries.enqueue(activity, recipients)
    end
  end

  @doc """
  Narrows `[{user, feed}]` recipients to those who can still see the activity's object and haven't seen it.

  Takes the activity so the object and its id are read once for the whole batch.
  """
  def still_to_notify(recipients, activity, opts \\ [])

  def still_to_notify([], _activity, _opts), do: []

  def still_to_notify(recipients, activity, _opts) do
    recipients
    |> reject_cannot_see(e(activity, :object, nil) || e(activity, :object_id, nil))
    |> reject_already_seen(Types.uid(activity))
    |> debug("recipients still to notify")
  end

  @doc """
  Where to deliver an activity, as one descriptor per recipient and target.

  A target is a device or address, so someone with two browsers and a phone is three of them, and
  someone with none is none: that is the point at which "who to notify" becomes "what to send
  where", and it is the last thing the fan-out decides before writing `deliver` jobs.

  One query per channel for the whole batch, and one preference read per recipient against settings
  that are already loaded. Verb comes from the activity, so the answer is per activity rather than
  per row.

  Which channels exist is `Bonfire.Notify.Channel.configured/0` rather than a branch per channel
  here, so a channel an instance hasn't configured costs no query and adding one is a config entry.
  """
  def targets(recipients, activity)

  def targets([], _activity), do: []

  def targets(recipients, activity) do
    # asked rather than called, since this extension doesn't depend on `bonfire_social`
    verb =
      Bonfire.Common.Utils.maybe_apply(Bonfire.Social.Activities, :verb_slug, [activity],
        fallback_return: nil
      )

    Enum.flat_map(Bonfire.Notify.Channel.configured(), fn {channel, adapter} ->
      # asked per channel, since a person can want mentions on their phone and not in a browser
      wanted =
        Enum.filter(recipients, fn {user, _feed} ->
          Bonfire.Notify.Preferences.enabled?(user, verb, channel)
        end)

      channel_targets(wanted, channel, adapter, verb)
    end)
  end

  defp channel_targets([], _channel, _adapter, _verb), do: []

  defp channel_targets(wanted, channel, adapter, verb) do
    feeds = Map.new(wanted, fn {user, feed} -> {Types.uid(user), feed} end)

    # the verb goes in so a target can narrow what the settings allowed: a client that switched this kind off, or a subscription set not to be pushed to at all
    adapter.targets(Map.keys(feeds), verb)
    |> Enum.map(fn target ->
      user_id = e(target, :user_id, nil)

      %{
        user_id: user_id,
        feed: feeds[user_id],
        channel: channel,
        target_id: e(target, :target_id, nil)
      }
    end)
  end

  defp reject_cannot_see(recipients, nil) do
    warn(recipients, "No object to check the boundary of, so notifying nobody")
    []
  end

  defp reject_cannot_see(recipients, object) do
    allowed =
      Boundaries.users_grants_on(Enum.map(recipients, fn {user, _feed} -> user end), object, [
        :see,
        :read
      ])
      |> Enum.map(&e(&1, :subject_id, nil))
      |> MapSet.new()

    Enum.filter(recipients, fn {user, _feed} -> MapSet.member?(allowed, Types.uid(user)) end)
  end

  defp reject_already_seen(recipients, nil), do: recipients

  defp reject_already_seen([], _activity_id), do: []

  defp reject_already_seen(recipients, activity_id) do
    seen = accounts_that_have_seen(recipients, activity_id)

    Enum.reject(recipients, fn {user, _feed} ->
      MapSet.member?(seen, account_id(user))
    end)
  end

  defp accounts_that_have_seen(recipients, activity_id) do
    account_ids =
      recipients
      |> Enum.map(fn {user, _feed} -> account_id(user) end)
      |> Enum.reject(&is_nil/1)

    if account_ids == [] do
      MapSet.new()
    else
      seen_table_id = Types.table_id(Seen)

      from(edge in Edge,
        where:
          edge.table_id == ^seen_table_id and edge.object_id == ^activity_id and
            edge.subject_id in ^account_ids,
        select: edge.subject_id
      )
      |> repo().many()
      |> MapSet.new()
    end
  end

  # Seen is tracked per account, so that is the subject to compare against
  defp account_id(user),
    do: Types.uid(e(user, :accounted, :account_id, nil) || e(user, :accounted, :account, nil))
end
