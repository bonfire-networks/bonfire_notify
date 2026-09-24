defmodule Bonfire.Notify.Digest do
  @moduledoc """
  The email digest: one email per account, with what reached each of its personas in its window, in the kinds of notification they left to the digest.

  A kind's Email setting is Off (`false`), Digest (unset) or Instant (`true`, emailed as it happened by `Bonfire.Notify.Email`), so only the Digest ones go in (`Bonfire.Notify.Preferences.digest_categories/1`), selected by the same `notification_categories:` filter the chips and switches use. An account with nothing waiting gets no email.

  Each notification renders as an instant email renders it (`Bonfire.Notify.EmailContent.activity_mjml/2`), inside `Bonfire.Notify.DigestEmail`: an intro, then a section per persona under a header naming them.

  `send_now/2` is what the admin's "Send me a test digest" button calls. The schedule sends through `send_due/1` instead, from a job the fan-out queues (`schedule/2`) when a notification left to the digest arrives, so only accounts with something waiting ever get one.

  When an account's last digest went out is a Seen edge from the account to the Message verb: one per account, replaced on each send, whose ULID id records when. The object is a fixed pointer because the digest is per account while every notifications feed is a persona's, and it never collides with the Seen edges sign-in writes (account to persona or to itself) or feed visits write (account to activity).
  """
  use Bonfire.Common.E
  use Bonfire.Common.Config
  use Bonfire.Common.Settings
  use Bonfire.Common.Localise
  import Untangle
  import Ecto.Query, only: [from: 2]

  alias Bonfire.Common.DatesTimes
  alias Bonfire.Notify.EmailContent
  alias Bonfire.Notify.Preferences

  @doc """
  Sends this account its digest now, to its address. `{:ok, email}` once sent, `{:ok, :nothing}` when nothing is waiting, or an error.

  Options: `since:` how far back to look (default a first digest's look-back), and `range:` (`:daily`, `:weekly` or `:monthly`) for what the subject says it covers (default the person's own digest frequency).
  """
  def send_now(account, opts \\ []) do
    account = Bonfire.Common.Repo.maybe_preload(account, :email)
    since = opts[:since] || first_look_back()

    personas =
      account
      |> Bonfire.Me.Users.by_account()
      |> Bonfire.Common.Repo.maybe_preload([
        :settings,
        :profile,
        character: [:peered],
        accounted: [account: [:settings]]
      ])

    case personas |> Enum.map(&section(&1, since)) |> Enum.reject(&is_nil/1) do
      [] ->
        {:ok, :nothing}

      sections ->
        Bonfire.Mailer.new()
        |> Bonfire.Mailer.subject(subject(opts[:range] || frequency(List.first(personas))))
        |> Bonfire.Mailer.Render.templated(Bonfire.Notify.DigestEmail, %{
          intro:
            l("Here's what happened on %{instance} since %{date}",
              instance: Bonfire.Mailer.app_name(),
              date: DatesTimes.format_date(since)
            ),
          sections: sections
        })
        |> Bonfire.Mailer.send_now(e(account, :email, :email_address, nil))
    end
  end

  @doc """
  Sends this account the digest it is due and records it as sent, including when there was nothing to send, so the next one is due an interval from now.

  It covers from `since`, when the notification that queued it arrived, or from the last digest if that is later. Anything earlier arrived while that kind was not left to the digest, or while the digest was Never, so it was either emailed already or not wanted. With neither (a job queued before `since` was recorded), from the first look-back.
  """
  def send_due(account, since \\ nil) do
    window_start =
      [since, last_sent(account)]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> first_look_back() end)

    with {:ok, _} = sent <- send_now(account, since: window_start) do
      record_sent(account)
      sent
    end
  end

  @doc """
  Queues this account's digest for when it is next due, on this persona's frequency: an interval after the last one, or an interval from now for a first. It covers from `since`, when the notification queuing it arrived. Nothing for Never, and nothing more while one is already waiting.
  """
  def schedule(account_id, user, %DateTime{} = since) do
    case frequency(user) do
      :never ->
        :skip

      frequency ->
        Bonfire.Notify.Worker.enqueue_digest(
          account_id,
          DateTime.add(last_sent(user) || DateTime.utc_now(), interval_days(frequency), :day),
          since
        )
    end
  end

  @doc """
  Moves this account's waiting digest to its new due time after its frequency changed, or cancels it for Never, keeping what it covers from. With none waiting there is nothing to move: the next notification queues one.
  """
  def reschedule(user) do
    account_id =
      Bonfire.Common.Types.uid(e(user, :accounted, :account_id, nil) || e(user, :account, nil))

    waiting = Bonfire.Notify.Worker.waiting_digests(account_id)

    with %Oban.Job{args: args} <- Bonfire.Common.Repo.one(from(job in waiting, limit: 1)),
         {:ok, cancelled} when cancelled > 0 <-
           Oban.cancel_all_jobs(Bonfire.Common.TestInstanceRepo.oban_name(), waiting) do
      schedule(
        account_id,
        user,
        Bonfire.Notify.Worker.digest_since(args) || DateTime.utc_now()
      )
    else
      _ -> :skip
    end
  end

  # asked rather than called, since this extension doesn't depend on `bonfire_social`, which owns Seen
  defp last_sent(account_or_user) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Seen,
      :last_date,
      [account_or_user, sent_marker()],
      fallback_return: nil
    )
  end

  defp record_sent(account) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Seen,
      :mark_seen,
      [account, sent_marker(), [upsert: true]],
      fallback_return: nil
    )
  end

  # a map rather than a bare id, which `Seen.mark_seen/3` would first load through a boundary check a verb row may not pass
  defp sent_marker, do: %{id: Bonfire.Boundaries.Verbs.get_id!(:message)}

  defp interval_days(:weekly), do: 7
  defp interval_days(:monthly), do: 30
  defp interval_days(_daily), do: 1

  # one persona's part: what reached it since `since`, in the kinds it left to the digest, or nil when there is nothing
  defp section(user, since) do
    with [_ | _] = categories <- Preferences.digest_categories(user),
         [_ | _] = activities <- pending(user, categories, since) do
      %{
        name: e(user, :profile, :name, nil),
        username: e(user, :character, :username, nil),
        count: length(activities),
        activities:
          activities
          |> Enum.map(&EmailContent.activity_mjml(&1, user))
          |> Enum.reject(&is_nil/1)
      }
    else
      _ -> nil
    end
  end

  defp pending(user, categories, since) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.FeedLoader,
      :feed,
      [
        :notifications,
        %{notification_categories: categories},
        [current_user: user, limit: limit()]
      ],
      fallback_return: %{edges: []}
    )
    |> e(:edges, [])
    |> Enum.map(&(e(&1, :activity, nil) || &1))
    # not filtered by Seen: visiting the notifications page marks the whole feed seen, so anyone visiting daily would get empty digests; the window since the last digest is what keeps digests from repeating each other
    |> Enum.filter(&newer?(&1, since))
  end

  defp newer?(activity, since) do
    case DatesTimes.date_from_pointer(activity) do
      %DateTime{} = at -> DateTime.compare(at, since) != :lt
      _ -> false
    end
  end

  # what it covers, by how often this person asked for a digest (or the `range:` a caller gives), each a whole sentence so it translates as one
  defp subject(:weekly), do: l("What happened this week")
  defp subject(:monthly), do: l("What happened this month")
  defp subject(_daily), do: l("What happened today")

  defp frequency(user) do
    # the instance's default, when this person has not chosen, is in config (`Bonfire.Notify.RuntimeConfig`), so nothing unset reads as a frequency here
    case Settings.get([:notifications, :email_digest], :never, context: user) do
      frequency when frequency in [:daily, "daily"] -> :daily
      frequency when frequency in [:weekly, "weekly"] -> :weekly
      frequency when frequency in [:monthly, "monthly"] -> :monthly
      _ -> :never
    end
  end

  # how far back a first digest looks, so turning it on does not email a year of history
  defp first_look_back do
    days =
      Config.get([__MODULE__, :first_look_back_days], 7,
        name: l("First digest look-back"),
        description: l("How many days back a first email digest looks.")
      )

    DateTime.add(DateTime.utc_now(), -days, :day)
  end

  defp limit do
    Config.get([__MODULE__, :limit], 50,
      name: l("Digest size"),
      description: l("How many notifications one persona's part of a digest shows at most.")
    )
  end
end
