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

  # a denial is a grant too, with `value: false`, and must count against them rather than for them
  test "a recipient denied seeing and reading an otherwise public object is dropped", %{
    alice: alice,
    bob: bob
  } do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "public, except for bob"}},
        boundary: "public",
        to_circles: [{bob.id, verbs: [see: false, read: false]}]
      )

    refute Bonfire.Boundaries.can?(bob, :read, post), "control: the denial took"

    assert Bonfire.Boundaries.can?(Bonfire.Me.Fake.fake_user!(), :read, post),
           "control: anyone else may read it"

    assert [] = FanOut.still_to_notify(recipients_for([bob]), e(post, :activity, nil))
  end

  # a notification row can be written for someone who can't read the post (the rows go in with the post, before its boundary exists to check), and it must not reach their badge: the fan-out removes it and bumps only the counters of who can
  test "someone who can't see it loses the row and isn't counted, someone who can is counted", %{
    alice: alice,
    bob: bob
  } do
    carol = Bonfire.Me.Fake.fake_user!()

    {:ok, private} =
      Bonfire.Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "@#{carol.character.username} just for you"}},
        boundary: "mentions"
      )

    activity = e(private, :activity, nil)
    bobs_feed = Feeds.my_feed_id(:notifications, bob)
    carols_feed = Feeds.my_feed_id(:notifications, carol)

    # the row a bell of bob's above it would have written
    Bonfire.Common.Repo.insert_all(Bonfire.Data.Social.FeedPublish, [
      %{id: activity.id, feed_id: bobs_feed}
    ])

    :ok = Bonfire.Common.PubSub.subscribe("unseen_count:#{bobs_feed}", current_user: bob)
    :ok = Bonfire.Common.PubSub.subscribe("unseen_count:#{carols_feed}", current_user: carol)

    FanOut.notify(activity, %{
      recipients: [%{"user_id" => bob.id}, %{"user_id" => carol.id}],
      feeds: []
    })

    assert_receive {{Bonfire.Social.Feeds, :count_increment}, %{feed_id: ^carols_feed}}
    refute_receive {{Bonfire.Social.Feeds, :count_increment}, %{feed_id: ^bobs_feed}}

    # the positive first: carol, who can read it, keeps hers
    assert row?(activity, carols_feed)

    refute row?(activity, bobs_feed),
           "bob can't read it, so it isn't in his notifications to count"
  end

  defp row?(activity, feed_id) do
    import Ecto.Query

    Bonfire.Common.Repo.exists?(
      from(fp in Bonfire.Data.Social.FeedPublish,
        where: fp.id == ^activity.id and fp.feed_id == ^feed_id
      )
    )
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

    # who you hear from applies to delivery too: a hidden audience's notifications reach no device, while the badge still counts them (they're under Hidden)
    test "a like from an audience someone hides reaches none of their devices; from others it does",
         %{alice: alice, bob: bob} do
      configure_native_push()

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      {:ok, bobs_post} =
        Bonfire.Posts.publish(
          current_user: bob,
          post_attrs: %{post_content: %{html_body: "something to like"}},
          boundary: "public"
        )

      {:ok, like} = Bonfire.Social.Likes.like(alice, bobs_post)
      job = %{recipients: [%{"user_id" => bob.id}], feeds: []}

      # the positive first: nothing hidden, the like reaches bob's phone
      assert {:ok, %{deliveries: 1}} = FanOut.notify(e(like, :activity, nil), job)

      Bonfire.Common.Settings.put(
        Bonfire.Social.Notifications.audience_key(:not_followed),
        :hide,
        current_user: bob
      )

      assert {:ok, %{deliveries: 0}} = FanOut.notify(e(like, :activity, nil), job),
             "bob doesn't follow alice and hides people he doesn't follow"

      {:ok, _} = Bonfire.Social.Graph.Follows.follow(bob, alice)

      assert {:ok, %{deliveries: 1}} = FanOut.notify(e(like, :activity, nil), job),
             "once he follows her, she's no longer in that audience"
    end

    # what you filter applies to delivery too: a post with one of your filtered keywords reaches none of your devices, while it still counts in your notifications (where it shows as a placeholder)
    test "a post with one of bob's filtered keywords reaches none of his devices but still counts for him; carol's phone gets it",
         %{alice: alice, bob: bob} do
      configure_native_push()
      carol = Bonfire.Me.Fake.fake_user!()

      for user <- [bob, carol] do
        {:ok, _} =
          Bonfire.Notify.NativePush.register(user, %{provider: "apns", token: "t-#{user.id}"})
      end

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "Cheap viagra here"}},
          boundary: "public"
        )

      activity = e(post, :activity, nil)
      job = %{recipients: [%{"user_id" => bob.id}, %{"user_id" => carol.id}], feeds: []}

      # the positive first: nobody filters anything, both phones get it
      assert {:ok, %{deliveries: 2}} = FanOut.notify(activity, job)

      {:ok, _} =
        Bonfire.Boundaries.BlockKeywords.put_block_keywords_settings(["viagra"],
          current_user: bob
        )

      bobs_feed = Feeds.my_feed_id(:notifications, bob)
      :ok = Bonfire.Common.PubSub.subscribe("unseen_count:#{bobs_feed}", current_user: bob)

      assert {:ok, %{deliveries: 1}} = FanOut.notify(activity, job),
             "bob filters \"viagra\", so it reaches none of his devices"

      assert_receive {{Bonfire.Social.Feeds, :count_increment}, %{feed_id: ^bobs_feed}},
                     500,
                     "it still counts in bob's notifications"

      # 2 from the first notify, 1 from the second, which is carol's
      assert %{carol.id => 2, bob.id => 1} ==
               deliver_jobs() |> Enum.map(&e(&1, :args, "user_id", nil)) |> Enum.frequencies()
    end

    # a post someone hides behind a warning is no more pushed than one they hide completely: a notification on a device shows the text
    test "a post with a keyword bob hides behind a warning reaches none of his devices either; carol's phone gets it",
         %{alice: alice, bob: bob} do
      configure_native_push()
      carol = Bonfire.Me.Fake.fake_user!()

      for user <- [bob, carol] do
        {:ok, _} =
          Bonfire.Notify.NativePush.register(user, %{provider: "apns", token: "t-#{user.id}"})
      end

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "a spoiler about the ending"}},
          boundary: "public"
        )

      activity = e(post, :activity, nil)
      job = %{recipients: [%{"user_id" => bob.id}, %{"user_id" => carol.id}], feeds: []}

      # the positive first: nobody filters anything, both phones get it
      assert {:ok, %{deliveries: 2}} = FanOut.notify(activity, job)

      {:ok, _} =
        Bonfire.Boundaries.BlockKeywords.put_warn_keywords_settings(["spoiler"],
          current_user: bob
        )

      assert {:ok, %{deliveries: 1}} = FanOut.notify(activity, job),
             "bob hides \"spoiler\" behind a warning, so it reaches none of his devices"
    end

    # an audience that isn't relative to the reader is one condition shared by everyone who hides it
    test "a like from a user new to this server reaches no device of someone hiding new accounts",
         %{alice: alice, bob: bob} do
      configure_native_push()

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      {:ok, bobs_post} =
        Bonfire.Posts.publish(
          current_user: bob,
          post_attrs: %{post_content: %{html_body: "something to like"}},
          boundary: "public"
        )

      {:ok, like} = Bonfire.Social.Likes.like(alice, bobs_post)
      job = %{recipients: [%{"user_id" => bob.id}], feeds: []}

      # the positive first
      assert {:ok, %{deliveries: 1}} = FanOut.notify(e(like, :activity, nil), job)

      Bonfire.Common.Settings.put(
        Bonfire.Social.Notifications.audience_key(:new_accounts),
        :hide,
        current_user: bob
      )

      assert {:ok, %{deliveries: 0}} = FanOut.notify(e(like, :activity, nil), job),
             "alice was created just now, so she's new to this server"
    end

    # the same switches hide direct messages: a message reaches its recipient through their inbox, and is dropped from delivery by the same audience conditions as a notification
    test "a message from someone bob doesn't follow reaches none of his devices while he hides them",
         %{alice: alice, bob: bob} do
      configure_native_push()

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      {:ok, message} =
        Bonfire.Messages.send(alice, %{
          to_circles: [bob.id],
          post_content: %{html_body: "a message for bob"}
        })

      job = %{recipients: [%{"user_id" => bob.id}], feeds: [Feeds.feed_id(:inbox, bob)]}
      activity = e(message, :activity, nil)

      # the positive first: nothing hidden, the message reaches bob's phone
      assert {:ok, %{deliveries: 1}} = FanOut.notify(activity, job)

      Bonfire.Common.Settings.put(
        Bonfire.Social.Notifications.audience_key(:not_followed),
        :hide,
        current_user: bob
      )

      assert {:ok, %{deliveries: 0}} = FanOut.notify(activity, job),
             "bob doesn't follow alice and hides people he doesn't follow"

      {:ok, _} = Bonfire.Social.Graph.Follows.follow(bob, alice)

      assert {:ok, %{deliveries: 1}} = FanOut.notify(activity, job),
             "once he follows her, her messages reach him again"
    end

    # a message tags whoever it's addressed to, so it's a mention: a stranger's first message is making contact, and their answer in a conversation bob started isn't
    test "hiding strangers making contact stops a stranger's first message, not their reply to bob",
         %{alice: alice, bob: bob} do
      configure_native_push()

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      {:ok, first} =
        Bonfire.Messages.send(alice, %{
          to_circles: [bob.id],
          post_content: %{html_body: "hello bob, we haven't met"}
        })

      {:ok, bobs} =
        Bonfire.Messages.send(bob, %{
          to_circles: [alice.id],
          post_content: %{html_body: "bob writes"}
        })

      {:ok, reply} =
        Bonfire.Messages.send(alice, %{
          to_circles: [bob.id],
          post_content: %{html_body: "alice answers"},
          reply_to_id: bobs.id
        })

      job = %{recipients: [%{"user_id" => bob.id}], feeds: [Feeds.feed_id(:inbox, bob)]}

      # the positive first, for both
      assert {:ok, %{deliveries: 1}} = FanOut.notify(e(first, :activity, nil), job)
      assert {:ok, %{deliveries: 1}} = FanOut.notify(e(reply, :activity, nil), job)

      Bonfire.Common.Settings.put(
        Bonfire.Social.Notifications.audience_key(:not_followed_making_contact),
        :hide,
        current_user: bob
      )

      assert {:ok, %{deliveries: 0}} = FanOut.notify(e(first, :activity, nil), job)

      assert {:ok, %{deliveries: 1}} = FanOut.notify(e(reply, :activity, nil), job),
             "an answer in a conversation bob started isn't a stranger making contact"
    end

    # a reply below something you wrote is Replies, and one in a discussion you only follow is Other, as the chips put them: the write path says which of the recipients wrote the post they follow it by (`wrote_above`)
    test "a reply in a discussion you only follow follows Other's Push switch, not Replies'", %{
      alice: alice,
      bob: bob,
      post: alices_post
    } do
      configure_native_push()

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      {:ok, reply} =
        Bonfire.Posts.publish(
          current_user: Bonfire.Me.Fake.fake_user!(),
          post_attrs: %{
            post_content: %{html_body: "answering alice"},
            reply_to_id: alices_post.id
          },
          boundary: "public"
        )

      reply_activity = e(reply, :activity, nil)
      # bob follows alice's discussion without having written anything in it
      job = %{recipients: [%{"user_id" => bob.id}], feeds: [], wrote_above: [alice.id]}

      Bonfire.Common.Settings.put([:notifications, :push, :extra_replies], false,
        current_user: bob
      )

      assert {:ok, %{deliveries: 1}} = FanOut.notify(reply_activity, job),
             "Replies switched off leaves a followed discussion's replies alone"

      Bonfire.Common.Settings.put([:notifications, :push, :other], false, current_user: bob)

      assert {:ok, %{deliveries: 0}} = FanOut.notify(reply_activity, job),
             "Other switched off stops them"
    end

    test "a request to join a group is pushed to its moderator as a request to join, not to follow",
         %{bob: bob} do
      configure_native_push()

      group = Bonfire.Classify.Simulate.fake_group!(bob, %{membership: "on_request"})
      asker = Bonfire.Me.Fake.fake_user!()
      {:ok, %{requested: true}} = Bonfire.Classify.Categories.join_group(asker, group)

      {:ok, request} =
        Bonfire.Social.Requests.get(asker, Bonfire.Boundaries.Verbs.get_id!(:join), group,
          skip_boundary_check: true
        )

      # as the fan-out job has it: read by id, so whatever it needs it loads itself
      {:ok, activity} =
        Bonfire.Social.Activities.get(Bonfire.Common.Types.uid(request),
          skip_boundary_check: true
        )

      # registered after the request, so the only delivery is the one this notifies
      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      assert {:ok, %{deliveries: 1}} =
               FanOut.notify(activity, %{recipients: [%{"user_id" => bob.id}], feeds: []})

      assert [job] = deliver_jobs()
      title = e(job, :args, "payload", "title", nil)
      assert title =~ "requested to join"
      refute title =~ "requested to follow"

      # a request opens where it can be accepted or declined, not at the group
      assert e(job, :args, "payload", "url", nil) == "/notifications/requests"
    end

    test "a request to follow is pushed with a link to where it can be accepted" do
      configure_native_push()

      private =
        Bonfire.Me.Fake.fake_user!(Bonfire.Me.Fake.fake_account!(), %{},
          request_before_follow: true
        )

      asker = Bonfire.Me.Fake.fake_user!()

      {:ok, request} = Bonfire.Social.Graph.Follows.follow(asker, private)

      {:ok, activity} =
        Bonfire.Social.Activities.get(Bonfire.Common.Types.uid(request),
          skip_boundary_check: true
        )

      {:ok, _} =
        Bonfire.Notify.NativePush.register(private, %{provider: "apns", token: "t-#{private.id}"})

      assert {:ok, %{deliveries: 1}} =
               FanOut.notify(activity, %{recipients: [%{"user_id" => private.id}], feeds: []})

      assert [job] = deliver_jobs()
      assert e(job, :args, "payload", "url", nil) == "/notifications/requests"
    end

    # what a follow is about, to the one followed, is who followed them, as its row and its body already say
    test "a follow is pushed with a link to the follower, not to the one followed", %{bob: bob} do
      configure_native_push()
      follower = Bonfire.Me.Fake.fake_user!()

      {:ok, follow} = Bonfire.Social.Graph.Follows.follow(follower, bob)

      # as the fan-out job has it: read by id, so whatever it needs it loads itself
      {:ok, activity} =
        Bonfire.Social.Activities.get(Bonfire.Common.Types.uid(follow), skip_boundary_check: true)

      {:ok, _} =
        Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

      assert {:ok, %{deliveries: 1}} =
               FanOut.notify(activity, %{recipients: [%{"user_id" => bob.id}], feeds: []})

      assert [job] = deliver_jobs()
      url = e(job, :args, "payload", "url", nil)

      # a profile has more than one path, so whose it is shows in the username
      assert is_binary(url) and
               String.ends_with?(url, [
                 "/" <> follower.character.username,
                 "/@" <> follower.character.username
               ]),
             "pushed with #{inspect(url)}, the follower being @#{follower.character.username} and the one followed @#{e(bob, :character, :username, nil)}"
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

  # a post scheduled for later: the notifications feed row exists at once but is hidden by date, push and the rest wait for the date like federation does
  test "a post scheduled for later notifies a mentioned local user at its date, not at publish time",
       %{
         alice: alice,
         bob: bob
       } do
    import Ecto.Query

    configure_native_push()

    {:ok, _} = Bonfire.Notify.NativePush.register(bob, %{provider: "apns", token: "t-#{bob.id}"})

    future = DateTime.utc_now() |> DateTime.add(7, :day)

    # the setup's public post queued its own federation job, so only the jobs this publish adds count
    federation_jobs = fn ->
      Bonfire.Common.Repo.all(
        from(j in Oban.Job, where: j.worker == "ActivityPub.Federator.Workers.PublisherWorker")
      )
    end

    already_queued = Enum.map(federation_jobs.(), & &1.id)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: alice,
        post_attrs: %{
          post_content: %{html_body: "scheduled, hello @#{bob.character.username}"},
          scheduled_at: DateTime.to_iso8601(future)
        },
        boundary: "public"
      )

    {:ok, ulid_ts} = Needle.ULID.timestamp(post.id)
    assert ulid_ts > DateTime.to_unix(DateTime.utc_now(), :millisecond), "the post is scheduled"

    # (a) the notifications feed row exists now
    bobs_feed = Feeds.my_feed_id(:notifications, bob)

    assert Bonfire.Common.Repo.exists?(
             from(fp in Bonfire.Data.Social.FeedPublish,
               where: fp.id == ^post.id and fp.feed_id == ^bobs_feed
             )
           ),
           "no notifications feed row for the mentioned user"

    # (b) nothing is delivered now: one fan_out job waits for the post's date
    assert deliver_jobs() == []
    activity_id = e(post, :activity, :id, nil) || post.id

    assert [fan_out] =
             Enum.filter(
               enqueued_ops("fan_out"),
               &(e(&1, :args, "activity_id", nil) == activity_id)
             )

    assert DateTime.compare(fan_out.scheduled_at, DateTime.utc_now()) == :gt
    assert DateTime.diff(fan_out.scheduled_at, future, :second) |> abs() < 5

    # (b2) the feed read hides the post until its date
    refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, post, current_user: bob),
           "the scheduled post is listed in the mentioned user's notifications early"

    # (b3) when the job runs, the delivery is queued
    assert :ok =
             Oban.Testing.perform_job(Bonfire.Notify.Worker, fan_out.args,
               repo: Bonfire.Common.Repo
             )

    assert [deliver] = deliver_jobs()
    assert e(deliver, :args, "user_id", nil) == bob.id

    # (c) federation is queued for the date, none now
    assert [federation_job] = Enum.reject(federation_jobs.(), &(&1.id in already_queued))

    assert DateTime.compare(federation_job.scheduled_at, DateTime.utc_now()) == :gt,
           "the post is federated at publish time"

    assert DateTime.diff(federation_job.scheduled_at, future, :second) |> abs() < 5
  end

  defp enqueued_ops(op) do
    Oban.Testing.all_enqueued(Bonfire.Common.Repo, worker: Bonfire.Notify.Worker)
    |> Enum.filter(&(e(&1, :args, "op", nil) == op))
  end

  defp deliver_jobs, do: enqueued_ops("deliver")
end
