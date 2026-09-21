defmodule Bonfire.Notify.Worker do
  @moduledoc """
  Turns "this activity reached someone's notifications feed" into durable deliveries.

  Two ops, shaped like `ActivityPub.Federator.Workers.PublisherWorker`'s `publish` and `publish_one`:

    * `fan_out` — works out who is still worth notifying and on what, assembles what the notification says once per language they read, and inserts one `deliver` job per device. Runs `Bonfire.Notify.FanOut.notify/3`, the same function a caller can run inline, so using the queue changes when the work happens and nothing about what it does.
    * `deliver` — puts one finished payload on one target's wire and turns the answer into what this job should do next.

  Enqueued either by `Bonfire.Social.FeedActivities.maybe_enqueue_notify/2` inside the same transaction as the FeedPublish rows, so a publish that rolls back takes its notifications with it, or by a caller that ran the fan-out inline and only needs the deliveries queued.
  """
  @queue_atom :notify

  # How many times a delivery is worth retrying before it is given up on. Compile-time because that is when Oban reads a worker's defaults, so changing it is a rebuild rather than a setting; a per-job override at insert time is what to add if that ever needs to be live
  @max_attempts Application.compile_env(:bonfire_notify, [__MODULE__, :max_attempts], 5)

  use Oban.Worker,
    queue: @queue_atom,
    max_attempts: @max_attempts

  import Untangle
  import Ecto.Query
  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  use Bonfire.Common.E
  use Bonfire.Common.Repo

  @doc """
  Whether the `notify` queue is configured on this instance.

  This extension declares it (`Bonfire.Notify.RuntimeConfig`), but a flavour can replace the queue list wholesale, and then jobs would be inserted and never run, hence this check at boot.
  """
  def queue_configured? do
    case Oban.config() do
      %{queues: queues} when is_list(queues) -> Keyword.has_key?(queues, @queue_atom)
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Enqueues the fan-out for an activity that reached someone's notifications.

  Called from `Bonfire.Social.FeedActivities.maybe_enqueue_notify/2` inside the publish's own transaction, so the job cannot outlive a rollback. Failing to queue must NOT fail the publish: the feed rows are the record and the notification is a consequence of them, so a missing Oban instance costs a notification rather than a post.

  Inserts through `TestInstanceRepo.oban_insert/1` rather than `Oban.insert/1`, which picks the Oban instance belonging to the current repo context: in federation tests two instances run side by side and the bare call would enqueue into the wrong one.
  """
  def enqueue_fan_out(activity_id, notifying) when is_binary(activity_id) do
    %{
      "op" => "fan_out",
      "activity_id" => activity_id,
      # the recipients the write path had already resolved, each with the feed that reached them, and the notifying feeds for whatever it hadn't (a circle's notifications, the admin feeds)
      "recipients" =>
        Enum.map(e(notifying, :recipients, []), fn recipient ->
          %{
            "user_id" => e(recipient, :user_id, nil),
            "feed" => to_string(e(recipient, :feed, :notifications))
          }
        end),
      "feed_ids" => e(notifying, :feeds, [])
    }
    |> new()
    |> Bonfire.Common.TestInstanceRepo.oban_insert()
    |> debug("enqueued a notify fan_out")
  rescue
    exception ->
      error(exception, "Could not enqueue a notify fan_out, the activity is published anyway")
      :skip
  end

  def enqueue_fan_out(activity_id, notifying) do
    error(activity_id, "Cannot notify #{inspect(notifying)} without an activity id")
    :skip
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => "fan_out", "activity_id" => activity_id} = args}) do
    case existing_activity(activity_id) do
      {:ok, activity} ->
        # the same function a caller runs inline, so queueing changes when the work happens and nothing about what it does
        Bonfire.Notify.FanOut.notify(activity, %{
          recipients: e(args, "recipients", []),
          feeds: e(args, "feed_ids", [])
        })
        |> case do
          {:ok, _} -> :ok
          other -> other
        end

      _ ->
        # deleted between publishing and running: nothing to deliver, and retrying won't bring it back
        debug(activity_id, "the activity is gone, so nobody is notified")
        {:cancel, :gone}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "op" => "deliver",
            "activity_id" => activity_id,
            "user_id" => user_id,
            "channel" => channel,
            "target_id" => target_id,
            "payload" => payload
          } = args,
        inserted_at: inserted_at
      }) do
    with {:ok, adapter} <- Bonfire.Notify.Channel.adapter(channel),
         :ok <- still_exists(activity_id, inserted_at),
         {:ok, target} <- adapter.target(target_id, user_id) do
      # what to say was assembled by the fan-out, in this recipient's language, so all that is left is putting it on the wire
      adapter.deliver(target, payload, send_opts(args))
      |> debug("delivered #{inspect(channel)} to #{inspect(target_id)}")
    else
      {:error, :unknown_channel} ->
        error(args, "No such delivery channel on this instance")
        {:cancel, :unknown_channel}

      {:error, :gone} ->
        # deleted, or its transaction rolled back, while this waited in the queue
        debug(activity_id, "the activity is gone, so there is nothing to deliver")
        {:cancel, :gone}

      {:error, :inactive} ->
        # the endpoint rotated, the device was deregistered, or it now belongs to someone else
        debug(target_id, "the target is gone, so this delivery has nowhere to go")
        {:cancel, :inactive}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    error(args, "Unknown notify op")
    {:cancel, :unknown_op}
  end

  # Whether an activity is still there to be delivered, asked only of a delivery that waited.
  # The content a delivery carries was assembled while the activity existed, so the one thing that can have changed is whether it still does: the author deleted their post, a moderator removed it, or the publish's outer transaction rolled back after the fan-out had run.
  # A delivery that runs the moment it was inserted cannot have outlived its activity, so it skips the lookup and the common case costs nothing. Anything that waited pays one indexed lookup: a snooze after a rate limit, a retry after a failed send, a queue backed up behind a large fan-out, or one paused over a deploy. Judged on elapsed time rather than attempt count, because a snooze re-schedules the job and so the count cannot answer it, which is the same reason `ActivityPub.Federator.APPublisher` carries `queued_at` into its own staleness check
  defp still_exists(activity_id, inserted_at) do
    if waited?(inserted_at) do
      if repo().exists?(from(a in Bonfire.Data.Social.Activity, where: a.id == ^activity_id)),
        do: :ok,
        else: {:error, :gone}
    else
      :ok
    end
  end

  defp waited?(%NaiveDateTime{} = inserted_at),
    do: NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at, :millisecond) >= recheck_after()

  defp waited?(%DateTime{} = inserted_at),
    do: DateTime.diff(DateTime.utc_now(), inserted_at, :millisecond) >= recheck_after()

  # no idea how long it waited, so assume it did
  defp waited?(_), do: true

  defp recheck_after do
    Config.get([__MODULE__, :recheck_after], to_timeout(second: 5),
      name: l("Re-check a delayed notification"),
      description:
        l(
          "How long a delivery has to have waited before it checks that what it is about still exists."
        )
    )
  end

  # what the fan-out worked out for this verb, as the transport's own options
  defp send_opts(args) do
    [
      ttl: e(args, "ttl", nil),
      urgency: Bonfire.Common.Types.maybe_to_atom!(e(args, "urgency", nil)),
      topic: e(args, "topic", nil)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # asked rather than called, since this extension doesn't depend on `bonfire_social`, and with no social there is nothing to notify about. Boundaries are skipped here because the fan-out then checks the whole recipient batch against this object in one query
  defp existing_activity(activity_id) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Activities,
      :get,
      [activity_id, [skip_boundary_check: true]],
      fallback_return: nil
    )
    |> case do
      {:ok, activity} -> {:ok, activity}
      _ -> {:error, :gone}
    end
  end
end
