defmodule Bonfire.Notify.WorkerTest do
  @moduledoc """
  The fan-out job, which turns one notified activity into one delivery per device.

  The job decides everything when it runs: whether the activity still exists, who is still worth notifying, and which devices they have. Someone with a browser and a phone is two deliveries, someone with no device is none, and an activity that went away in the meantime is cancelled rather than retried, since retrying cannot bring it back.

  Deciding where to deliver stays batched: the queries are per channel, not per recipient, so a thread that notifies fifty people costs the same as one that notifies one.

  A delivery then only puts the payload it was given on the wire, since the fan-out already assembled it. What it still checks is that the activity exists, and only when it waited long enough for that to have changed: a snooze, a retry, or a queue backed up behind a large fan-out.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E
  import Bonfire.Common.Testing, only: [count_queries: 1]
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Common.Repo
  alias Bonfire.Notify.NativePush
  alias Bonfire.Notify.WebPush
  alias Bonfire.Notify.Worker

  setup do
    # a channel this instance can't send on has no targets and gets no delivery jobs, so both are configured here as an instance would
    configure_web_push()
    configure_native_push()

    alice = fake_user!()

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "something worth telling people about"}},
        boundary: "public"
      )

    {:ok, alice: alice, post: post}
  end

  defp fan_out_job(activity_id, users) do
    %Oban.Job{
      args: %{
        "op" => "fan_out",
        "activity_id" => activity_id,
        "recipients" => Enum.map(users, &%{"user_id" => &1.id, "feed" => "notifications"}),
        "feed_ids" => []
      }
    }
  end

  defp deliver_jobs do
    Oban.Testing.all_enqueued(Repo, worker: Worker)
    |> Enum.filter(&(e(&1, :args, "op", nil) == "deliver"))
  end

  defp with_web_push(user) do
    {:ok, _} =
      WebPush.subscribe(
        user.id,
        valid_push_subscription_map("https://push.bonfire.local/#{user.id}")
      )

    user
  end

  defp with_native_device(user) do
    {:ok, _} = NativePush.register(user, %{provider: "apns", token: "native-token-#{user.id}"})
    user
  end

  test "a browser and a phone are two deliveries, each naming its own target", %{post: post} do
    bob = fake_user!() |> with_web_push() |> with_native_device()

    assert :ok = Worker.perform(fan_out_job(post.id, [bob]))

    jobs = deliver_jobs()
    assert length(jobs) == 2

    assert jobs |> Enum.map(&e(&1, :args, "channel", nil)) |> Enum.sort() ==
             ["native_push", "web_push"]

    for job <- jobs do
      assert e(job, :args, "user_id", nil) == bob.id
      assert e(job, :args, "activity_id", nil) == post.id
      # the feed is carried through, since :inbox means a DM and is delivered differently
      assert e(job, :args, "feed", nil) == "notifications"

      assert e(job, :args, "target_id", nil),
             "a delivery without a target has nowhere to go"
    end
  end

  test "someone with no device gets no delivery, while someone with one does", %{post: post} do
    has_device = fake_user!() |> with_native_device()
    no_device = fake_user!()

    assert :ok = Worker.perform(fan_out_job(post.id, [has_device, no_device]))

    assert [job] = deliver_jobs()
    assert e(job, :args, "user_id", nil) == has_device.id
  end

  test "nobody with a device means no deliveries at all", %{post: post} do
    assert :ok = Worker.perform(fan_out_job(post.id, [fake_user!()]))
    assert deliver_jobs() == []
  end

  test "an activity that is gone is cancelled rather than retried", %{post: post} do
    bob = fake_user!() |> with_native_device()

    # the same recipient either way, so this tells cancelling apart from simply never delivering
    assert :ok = Worker.perform(fan_out_job(post.id, [bob]))
    assert [_] = deliver_jobs()

    assert {:cancel, :gone} = Worker.perform(fan_out_job(Needle.UID.generate(), [bob]))
    assert length(deliver_jobs()) == 1, "a missing activity should add no deliveries"
  end

  describe "delivering one of them" do
    defp deliver_job(post, user, target_id, opts \\ []) do
      %Oban.Job{
        args: %{
          "op" => "deliver",
          "activity_id" => Keyword.get(opts, :activity_id, post.id),
          "user_id" => user.id,
          "feed" => "notifications",
          "channel" => Keyword.get(opts, :channel, "web_push"),
          "target_id" => target_id,
          # what to say, not the bytes to send: the shape belongs to whatever is listening at the target
          "payload" => %{"title" => "Alice", "body" => "said something"},
          "ttl" => 3600,
          "urgency" => "high",
          "topic" => "01ABC"
        },
        inserted_at: Keyword.get(opts, :inserted_at, NaiveDateTime.utc_now())
      }
    end

    defp subscription_id(user) do
      assert [%{target_id: target_id}] = WebPush.targets([user.id])
      target_id
    end

    test "sends the payload it carries, with the options the fan-out worked out", %{post: post} do
      bob = fake_user!() |> with_web_push()

      assert :ok = Worker.perform(deliver_job(post, bob, subscription_id(bob)))

      assert_receive {:web_push_sent, _subscription, payload, opts}

      assert Jason.decode!(payload)["title"] == "Alice",
             "the delivery sends what it was given rather than assembling again"

      assert opts[:ttl] == 3600
      assert opts[:urgency] == :high
      assert opts[:topic] == "01ABC"
    end

    test "a channel this instance doesn't have is cancelled, not retried", %{post: post} do
      bob = fake_user!() |> with_web_push()

      assert {:cancel, :unknown_channel} =
               Worker.perform(
                 deliver_job(post, bob, subscription_id(bob), channel: "carrier_pigeon")
               )
    end

    test "a target that has gone is cancelled", %{post: post} do
      bob = fake_user!() |> with_web_push()
      target_id = subscription_id(bob)

      # the same job either way, so this tells cancelling apart from never having worked
      assert :ok = Worker.perform(deliver_job(post, bob, target_id))

      Bonfire.Notify.PushDevice.mark_status(
        repo().get!(Bonfire.Notify.PushDevice, target_id),
        {:expired, :gone}
      )

      assert {:cancel, :inactive} = Worker.perform(deliver_job(post, bob, target_id))
    end

    test "a delivery that waited checks the activity still exists", %{post: post} do
      bob = fake_user!() |> with_web_push()
      target_id = subscription_id(bob)

      waited = NaiveDateTime.add(NaiveDateTime.utc_now(), -60)

      # gone by the time it ran: deleted, moderated away, or its publish rolled back after the fan-out
      assert {:cancel, :gone} =
               Worker.perform(
                 deliver_job(post, bob, target_id,
                   activity_id: Needle.UID.generate(),
                   inserted_at: waited
                 )
               )

      assert :ok =
               Worker.perform(deliver_job(post, bob, target_id, inserted_at: waited)),
             "one that waited and is still there delivers as normal"
    end

    test "a delivery that didn't wait doesn't bother checking", %{post: post} do
      bob = fake_user!() |> with_web_push()

      # an activity nothing points at, delivered anyway because a job running the instant it was inserted cannot have outlived it. This is the lookup we are not paying for in the common case
      assert :ok =
               Worker.perform(
                 deliver_job(post, bob, subscription_id(bob), activity_id: Needle.UID.generate())
               )

      assert_receive {:web_push_sent, _subscription, _payload, _opts}
    end
  end

  test "the query count stays the same as recipients are added", %{post: post} do
    one = [fake_user!() |> with_native_device()]
    three = Enum.map(1..3, fn _ -> fake_user!() |> with_native_device() end)

    {_, queries_for_one} = count_queries(fn -> Worker.perform(fan_out_job(post.id, one)) end)
    {_, queries_for_three} = count_queries(fn -> Worker.perform(fan_out_job(post.id, three)) end)

    assert length(deliver_jobs()) == 4, "all four recipients should have been delivered to"

    assert queries_for_three == queries_for_one,
           "deciding where to deliver must be per channel, not per recipient"
  end
end
