defmodule Bonfire.Notify.FanOutTest do
  @moduledoc """
  Who is still worth notifying by the time the job runs.

  The job runs after the publish, so two things can have changed: the object's boundary, since a grant revoked in between must not be delivered, and whether the person has already seen it while the job waited. `Seen` is account-keyed, so one persona reading something counts for all of them.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E

  alias Bonfire.Notify.FanOut
  alias Bonfire.Notify.Recipients
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Seen

  setup do
    alice = Bonfire.Me.Fake.fake_user!()
    bob = Bonfire.Me.Fake.fake_user!()

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "something for bob to hear about"}},
        boundary: "public"
      )

    {:ok, alice: alice, bob: bob, post: post, activity: e(post, :activity, nil)}
  end

  defp recipients_for(users) do
    Recipients.for_job(Enum.map(users, &%{"user_id" => &1.id}))
  end

  test "a recipient who can see the object is still to notify", %{bob: bob, activity: activity} do
    assert [{user, :notifications}] =
             FanOut.still_to_notify(recipients_for([bob]), activity)

    assert user.id == bob.id
  end

  test "a recipient who cannot see the object is dropped", %{
    alice: alice,
    bob: bob,
    activity: activity
  } do
    {:ok, private} =
      Bonfire.Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "only for me"}},
        boundary: "mentions"
      )

    private_activity = e(private, :activity, nil)

    # the same recipient, one activity each way, so the test can tell filtering from emptiness
    assert [_] = FanOut.still_to_notify(recipients_for([bob]), activity)
    assert [] = FanOut.still_to_notify(recipients_for([bob]), private_activity)
  end

  test "a recipient who has already seen it is dropped", %{bob: bob, activity: activity} do
    assert [_] = FanOut.still_to_notify(recipients_for([bob]), activity)

    assert {:ok, _} = Seen.mark_seen(bob, activity)

    assert [] = FanOut.still_to_notify(recipients_for([bob]), activity)
  end

  test "seen counts per account, not per persona", %{activity: activity} do
    # two personas of one person
    account = Bonfire.Me.Fake.fake_account!()
    bob = Bonfire.Me.Fake.fake_user!(account)
    other_persona = Bonfire.Me.Fake.fake_user!(account)

    assert {:ok, _} = Seen.mark_seen(bob, activity)

    assert [] = FanOut.still_to_notify(recipients_for([other_persona]), activity),
           "one person reading something once is enough, whichever persona they were wearing"
  end

  test "nobody to notify needs no queries", %{activity: activity} do
    assert FanOut.still_to_notify([], activity) == []
  end

  describe "notifying, inline or queued" do
    test "inline, it reports what it enqueued", %{bob: bob, activity: activity} do
      configure_native_push()

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      assert {:ok, %{deliveries: 1}} =
               FanOut.notify(activity, %{recipients: [%{"user_id" => bob.id}], feeds: []}),
             "a caller running this inline has to be able to tell whether it worked"

      assert [_] = deliver_jobs()
    end

    test "inline, somebody with no device is nobody to deliver to", %{
      bob: bob,
      activity: activity
    } do
      configure_native_push()

      assert {:ok, %{deliveries: 0}} =
               FanOut.notify(activity, %{recipients: [%{"user_id" => bob.id}], feeds: []})

      assert deliver_jobs() == []
    end

    test "a category switched off in the panel's Push column is pushed to no device", %{
      alice: alice,
      bob: bob
    } do
      configure_native_push()

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      {:ok, bobs_post} =
        Bonfire.Posts.publish(
          current_user: bob,
          post_attrs: %{post_content: %{html_body: "something for alice to like"}},
          boundary: "public"
        )

      {:ok, like} = Bonfire.Social.Likes.like(alice, bobs_post)
      like_activity = e(like, :activity, nil)
      job = %{recipients: [%{"user_id" => bob.id}], feeds: []}

      # the positive first: with nothing switched off, the like reaches bob's phone
      assert {:ok, %{deliveries: 1}} = FanOut.notify(like_activity, job)

      # the key the panel's Push switch writes for the Reactions row (`NotificationPreferencesLive.push_key/1`): one switch for every push channel, a phone included
      Bonfire.Common.Settings.put([:notifications, :push, :react], false, current_user: bob)

      assert {:ok, %{deliveries: 0}} = FanOut.notify(like_activity, job),
             "switching Reactions off under Push has to stop them reaching a phone"
    end

    test "queued, it hands the whole thing to the worker instead", %{bob: bob, activity: activity} do
      configure_native_push()

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      FanOut.notify(activity, %{recipients: [%{"user_id" => bob.id}], feeds: []}, async: true)

      assert [job] = enqueued_ops("fan_out")
      assert e(job, :args, "activity_id", nil) == activity.id

      assert deliver_jobs() == [],
             "queued means later: nothing is delivered until the job runs"
    end
  end

  defp enqueued_ops(op) do
    Oban.Testing.all_enqueued(Bonfire.Common.Repo, worker: Bonfire.Notify.Worker)
    |> Enum.filter(&(e(&1, :args, "op", nil) == op))
  end

  defp deliver_jobs, do: enqueued_ops("deliver")
end
