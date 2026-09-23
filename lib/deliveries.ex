defmodule Bonfire.Notify.Deliveries do
  @moduledoc """
  Turning "these people, on these devices" into one queued delivery each.

  The notification is assembled here, once per language its recipients read, and each delivery job carries what it says. `ActivityPub.Federator.APPublisher` fans out the same way, preparing the outgoing JSON once and giving each `publish_one` job what one inbox needs, and the reason is the same: what a notification says is the same for everyone who gets it, so assembling it per delivery would pay N times over for one piece of work. Only the language differs, and there are far fewer languages than recipients.

  What each job carries is the content rather than finished bytes, because the *shape* is not the same for everyone: a Mastodon client reads a different payload than our own service worker, and which one a target is is known at delivery. Encoding is cheap and happens there; the expensive part, loading and describing the activity, still happens once.

  Deliveries are queued, whether the fan-out itself ran inline or in a job, because sending is what fails: a push service can be slow, rate-limited or down, and each device needs its own retry rather than one failure taking the others down with it. The exception is a channel that says it is immediate (`Bonfire.Notify.Channel.immediate?/1`), like showing a notification to whoever is connected, which is worth nothing late and has nothing to retry, so it is delivered here with the same assembled content.
  """
  use Bonfire.Common.Config
  use Bonfire.Common.Settings
  use Bonfire.Common.Localise
  use Bonfire.Common.E
  import Untangle

  alias Bonfire.Common.Types
  alias Bonfire.Notify.Content

  @doc """
  Enqueues one delivery per target, assembling what to say once per recipient language.

  Takes the targets to reach, the activity to say it about, and the recipients they belong to, whose loaded settings are where the languages come from, so grouping by language costs no query.
  """
  def enqueue(targets, activity, recipients)

  def enqueue([], activity, _recipients) do
    debug(activity, "nothing to deliver: nobody wanted this, or nobody has a device")
    {:ok, %{deliveries: 0}}
  end

  def enqueue(targets, activity, recipients) do
    activity_id = Types.uid(activity)
    languages = Map.new(recipients, fn {user, _feed} -> {Types.uid(user), language_of(user)} end)
    users = Map.new(recipients, fn {user, _feed} -> {Types.uid(user), user} end)

    jobs =
      targets
      |> Enum.group_by(&languages[e(&1, :user_id, nil)])
      |> Enum.flat_map(fn {language, its_targets} ->
        %{content: content, opts: send_opts} = assembled_in(language, activity)

        {now, queued} = Enum.split_with(its_targets, &immediate?/1)

        # delivered here rather than queued (`Bonfire.Notify.Channel.immediate?/1`), with the recipient as loaded, which is where such a channel finds where to send
        Enum.each(now, &deliver_now(&1, users[e(&1, :user_id, nil)], content, send_opts))

        Enum.map(queued, &job(&1, activity_id, content, send_opts))
      end)

    jobs
    # an instance-wide broadcast reaches everyone, so this can be thousands of rows: inserted in batches, since one statement has a limit on how many parameters it can carry
    |> Enum.chunk_every(batch_size())
    |> Enum.each(&Oban.insert_all(Bonfire.Common.TestInstanceRepo.oban_name(), &1))

    {:ok, %{deliveries: length(jobs)}}
  rescue
    exception ->
      # this runs inline for callers that can report, and a notification must never take the publish down with it: the activity is the record, so the error is returned for the caller to report rather than raised
      error(exception, "Could not enqueue notification deliveries")
  end

  defp immediate?(target) do
    case Bonfire.Notify.Channel.adapter(e(target, :channel, nil)) do
      {:ok, adapter} -> Bonfire.Notify.Channel.immediate?(adapter)
      _ -> false
    end
  end

  defp deliver_now(target, user, content, send_opts) do
    {:ok, adapter} = Bonfire.Notify.Channel.adapter(e(target, :channel, nil))
    adapter.deliver(Map.put(target, :user, user), content, send_opts)
  end

  defp job(target, activity_id, content, send_opts) do
    Bonfire.Notify.Worker.new(%{
      "op" => "deliver",
      "activity_id" => activity_id,
      "user_id" => e(target, :user_id, nil),
      "feed" => to_string(e(target, :feed, :notifications)),
      "channel" => to_string(e(target, :channel, nil)),
      "target_id" => e(target, :target_id, nil),
      # what to say, not the bytes to send: one activity can reach a client of ours and a Mastodon client, which read different shapes, so each delivery shapes its own at the wire
      "payload" => content,
      "ttl" => send_opts[:ttl],
      "urgency" => to_string(send_opts[:urgency]),
      "topic" => send_opts[:topic]
    })
  end

  # read from settings the recipients were loaded with, so this costs no query
  defp language_of(user),
    do: Settings.get([Bonfire.Common.Localise.Cldr, :default_locale], nil, context: user)

  defp assembled_in(nil, activity), do: Content.for_delivery(activity)

  defp assembled_in(language, activity) do
    previous = Bonfire.Common.Localise.get_locale()
    Bonfire.Common.Localise.put_locale(language)

    try do
      Content.for_delivery(activity)
    after
      # this goes on to assemble other languages, and whatever runs next in this process expects the language it had
      Bonfire.Common.Localise.put_locale(previous)
    end
  end

  defp batch_size do
    Config.get([__MODULE__, :batch_size], 500,
      name: l("Notification insert batch size"),
      description: l("How many deliveries to enqueue per insert when notifying many people.")
    )
  end
end
