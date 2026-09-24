defmodule Bonfire.Notify.Digest do
  @moduledoc """
  The email digest: one email per account, with what each of its personas has not seen yet, in the kinds of notification they left to the digest.

  A kind's Email setting is Off (`false`), Digest (unset) or Instant (`true`, emailed as it happened by `Bonfire.Notify.Email`), so only the Digest ones go in (`Bonfire.Notify.Preferences.digest_categories/1`), selected by the same `notification_categories:` filter the chips and switches use. An account with nothing waiting gets no email.

  Each notification renders as an instant email renders it (`Bonfire.Notify.EmailContent.activity_mjml/2`), inside `Bonfire.Notify.DigestEmail`: an intro, then a section per persona under a header naming them.

  `send_now/2` is what the admin's "Send me a test digest" button calls, and what the schedule will call for each account that is due.
  """
  use Bonfire.Common.E
  use Bonfire.Common.Config
  use Bonfire.Common.Settings
  use Bonfire.Common.Localise
  import Untangle

  alias Bonfire.Common.DatesTimes
  alias Bonfire.Notify.EmailContent
  alias Bonfire.Notify.Preferences

  @doc """
  Sends this account its digest now, to its address. `{:ok, email}` once sent, `{:ok, :nothing}` when nothing is waiting, or an error.
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
        count = sections |> Enum.map(& &1.count) |> Enum.sum()

        Bonfire.Mailer.new()
        |> Bonfire.Mailer.subject(subject(count, frequency(List.first(personas))))
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

  # one persona's part: what it has not seen since `since`, in the kinds it left to the digest, or nil when there is nothing
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
    # what they already saw in the notifications feed is not news
    |> Enum.reject(&e(&1, :seen, nil))
    |> Enum.filter(&newer?(&1, since))
  end

  defp newer?(activity, since) do
    case DatesTimes.date_from_pointer(activity) do
      %DateTime{} = at -> DateTime.compare(at, since) != :lt
      _ -> false
    end
  end

  # the count and the range it covers, by how often this person asked for a digest
  defp subject(count, frequency) do
    new = lp("%{count} new notification", "%{count} new notifications", count, count: count)

    range =
      case frequency do
        :weekly -> l("this week")
        :monthly -> l("this month")
        _ -> l("today")
      end

    "#{new} #{range}"
  end

  defp frequency(user) do
    case Settings.get([:notifications, :email_digest], :daily, context: user) do
      frequency when frequency in [:weekly, "weekly"] -> :weekly
      frequency when frequency in [:monthly, "monthly"] -> :monthly
      _ -> :daily
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
