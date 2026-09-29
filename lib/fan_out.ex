defmodule Bonfire.Notify.FanOut do
  @moduledoc """
  Deciding who is still worth notifying, once an activity's recipients are known.

  Two things can have changed between publishing and delivering, which is why this is checked in the job rather than at write time: the object's boundary (a grant revoked in between must not be delivered) and whether the person has already seen it (they were looking at the feed while the job
  waited). Both are one query for the whole batch.

  `Seen` is account-keyed, so reading something as one persona counts for all of them, which is deliberate.

  The boundary check is `Boundaries.users_grants_on/3` rather than a per-recipient `can?/3` or `load_pointers/2`, which would be one query each. It reads the same `Summary` view a feed's own filter does (`Boundaries.Queries.query_with_summary/2`), with the same circle expansion and the same negative precedence, so it sees what the reader would see in their feed. Blocks included: hiding or locking an object writes `:can_only_read`/`:cannot_participate_or_more` grants on its ACL, and blocking a person puts them in stereotype circles whose grants are in that view too.
  """
  use Bonfire.Common.Repo
  use Bonfire.Common.E
  import Ecto.Query
  import Untangle

  alias Bonfire.Boundaries
  alias Bonfire.Common.Enums
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
      # loaded once here, since what it was to each recipient (a mention, a reply to their post) turns on the same assocs the content is then assembled from
      activity = Bonfire.Notify.Content.preloaded(activity)

      resolved =
        Bonfire.Notify.Recipients.for_job(
          e(notifying, :recipients, []),
          e(notifying, :feeds, []),
          exclude: e(activity, :subject_id, nil) || e(activity, :subject, nil)
        )

      # the two checks of `still_to_notify/3` apart, since who can't see it is also who shouldn't have it in their notifications at all
      object = e(activity, :object, nil) || e(activity, :object_id, nil)
      seeing = reject_cannot_see(resolved, object)

      # only where a boundary was actually checked: with no object, nobody passes, and that says nothing about who may read it
      if object, do: remove_from_unseeing(resolved, seeing, activity)

      recipients = reject_already_seen(seeing, Types.uid(activity))
      bump_counters(recipients)

      # who you hear from: a notification from an audience someone hides still counts (it's under Hidden), but isn't pushed, emailed or put in a digest. One query for everyone who hides anything, none when nobody does
      hidden_ids =
        Bonfire.Common.Utils.maybe_apply(
          Bonfire.Social.Notifications,
          :hidden_from,
          [Types.uid(activity), Enum.map(recipients, fn {user, _feed} -> user end)],
          fallback_return: []
        )
        |> List.wrap()

      recipients =
        Enum.reject(recipients, fn {user, _feed} -> Enums.id(user) in hidden_ids end)

      by_experience =
        by_experience(recipients, activity, e(notifying, :wrote_above, nil))

      queue_digests(by_experience, activity)

      by_experience
      |> targets_by_experience()
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

  One query per channel and distinct experience, and one preference read per recipient against
  settings that are already loaded. Recipients are grouped by what the activity was for each of
  them, which is usually one or two groups (the person named in a post, and everybody who got it
  another way), so this stays a fixed small number of queries rather than one per recipient.

  Which channels exist is `Bonfire.Notify.Channel.configured/0` rather than a branch per channel
  here, so a channel an instance hasn't configured costs no query and adding one is a config entry.
  """
  def targets(recipients, activity)

  def targets([], _activity), do: []

  def targets(recipients, activity) do
    recipients
    |> by_experience(activity)
    |> targets_by_experience()
  end

  # grouped because what an activity IS depends on who is being told: one post is a mention to the person it names and a plain write to everybody else, and both their switch and a Mastodon client's alert keys turn on that difference. `wrote_above` is who, of those following a discussion, wrote the post they follow it by (`Feeds.to_notify_of_this/6`), so a reply is Replies to them and a followed discussion to the others; `nil` where the caller didn't say, and then a reply stays one
  defp by_experience(recipients, activity, wrote_above \\ nil),
    do:
      Enum.group_by(recipients, fn {user, _feed} ->
        experienced_as(activity, user,
          wrote_above: if(is_list(wrote_above), do: Enums.id(user) in wrote_above)
        )
      end)

  # the account of everyone who left this kind to the email digest gets its digest queued, once per account however many of its personas this reached, covering from this notification. Only where email is sent at all
  defp queue_digests(by_experience, activity) do
    since = Bonfire.Common.DatesTimes.date_from_pointer(activity) || DateTime.utc_now()

    if Keyword.has_key?(Bonfire.Notify.Channel.configured(), :email) do
      for {experience, group} <- by_experience,
          {user, _feed} <- group,
          Bonfire.Notify.Preferences.email_timing(user, experience) == :digest,
          account_id = account_id(user),
          not is_nil(account_id) do
        {account_id, user}
      end
      |> Enum.uniq_by(fn {account_id, _user} -> account_id end)
      |> Enum.each(fn {account_id, user} ->
        Bonfire.Notify.Digest.schedule(
          e(user, :accounted, :account, nil) || account_id,
          since
        )
      end)
    end
  end

  defp targets_by_experience(by_experience) do
    Enum.flat_map(Bonfire.Notify.Channel.configured(), fn {channel, adapter} ->
      Enum.flat_map(by_experience, fn {experience, group} ->
        # asked per channel, since a person can want mentions on their phone and not in a browser
        wanted =
          Enum.filter(group, fn {user, _feed} ->
            Bonfire.Notify.Preferences.enabled?(user, experience, channel)
          end)

        channel_targets(wanted, channel, adapter, experience)
      end)
    end)
  end

  # asked rather than called, since this extension doesn't depend on `bonfire_social`. Without it there is nothing to deliver anyway, and a nil reads as "nothing in particular", which the catch-all switch answers for
  defp experienced_as(activity, user, opts) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Activities,
      :experienced_as,
      [activity, user, opts],
      fallback_return: nil
    )
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
        target_id: e(target, :target_id, nil),
        # what it was to this recipient, which is what its wording is chosen by
        experience: verb
      }
    end)
  end

  # a notification row is written with the post, before its boundary exists to check, so someone who can't read it may have one: it goes, in one delete, and any page it was pushed to is told to hide it. Only when someone was dropped, so nothing for a post everyone may read
  defp remove_from_unseeing(resolved, seeing, activity) do
    seeing_ids = MapSet.new(seeing, fn {user, _feed} -> Enums.id(user) end)

    case resolved
         |> Enum.reject(fn {user, _feed} -> MapSet.member?(seeing_ids, Enums.id(user)) end)
         |> Enum.map(&feed_id_of/1)
         |> Enum.reject(&is_nil/1) do
      [] ->
        nil

      feed_ids ->
        activity_id = Types.uid(activity)

        from(fp in Bonfire.Data.Social.FeedPublish,
          where: fp.id == ^activity_id and fp.feed_id in ^feed_ids
        )
        |> repo().delete_all()

        Bonfire.Common.Utils.maybe_apply(Bonfire.Social.LivePush, :hide_live, [
          feed_ids,
          activity_id
        ])
    end
  end

  # one more unseen item for each who is still to be told, in the box it reached them in (`Bonfire.Social.LivePush` does it when this extension isn't installed)
  defp bump_counters(recipients) do
    recipients
    |> Enum.group_by(fn {_user, feed} -> feed end, &feed_id_of/1)
    |> Enum.each(fn {box, feed_ids} ->
      Bonfire.Common.Utils.maybe_apply(Bonfire.Social.LivePush, :increment_counters, [
        Enum.reject(feed_ids, &is_nil/1),
        box
      ])
    end)
  end

  defp feed_id_of({user, :inbox}), do: e(user, :character, :inbox_id, nil)
  defp feed_id_of({user, _notifications}), do: e(user, :character, :notifications_id, nil)

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
