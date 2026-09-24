defmodule Bonfire.Notify.DigestTest do
  @moduledoc """
  The digest: one email per account, with what reached each of its personas in its window, in the kinds they left to the digest, whether or not it was already seen in the feed.

  A kind's Email setting is Off (`false`), Digest (unset) or Instant (`true`). Instant kinds were already emailed as they happened and Off ones never are, so only the Digest ones go in. An account with nothing waiting gets no email at all.

  Sent here with `Bonfire.Notify.Digest.send_now/2`, which is what the admin's "Send me a test digest" button calls, and what the schedule will call for each account that is due.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E
  import Swoosh.TestAssertions

  alias Bonfire.Notify.Digest

  setup do
    # as `Bonfire.Mailer.SwooshTest` does, so what is sent comes back to this process
    Process.put([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour], Bonfire.Mailer.Swoosh)
    on_exit(fn -> Process.delete([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour]) end)

    account = Bonfire.Me.Fake.fake_account!()
    bob = Bonfire.Me.Fake.fake_user!(account)

    {:ok, account: account, bob: bob, alice: Bonfire.Me.Fake.fake_user!()}
  end

  defp liked(liker, author, text) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: text}},
        boundary: "public"
      )

    {:ok, like} = Bonfire.Social.Likes.like(liker, post)
    flush_sent_emails()
    like
  end

  # signing up can send mail of its own (asking to confirm the address), which is not what these tests are about
  defp flush_sent_emails do
    receive do
      {:email, _} -> flush_sent_emails()
    after
      0 -> :ok
    end
  end

  # the person with the setting, as a later read would find them
  defp set(user, keys, value),
    do:
      Bonfire.Common.Utils.current_user(
        Bonfire.Common.Settings.put(keys, value, current_user: user)
      )

  # back to no choice, as choosing Digest does (the throuple's middle segment deletes the setting: putting nil would keep the old value), then the person as a later read would find them, so a later `set/3` does not write the old value back
  defp unset(user, keys) do
    {:ok, _} = Bonfire.Common.Settings.delete(keys, current_user: user)
    Bonfire.Me.Users.get_current(user.id)
  end

  defp address(account) do
    Bonfire.Common.Repo.preload(account, :email).email.email_address
  end

  test "what a persona has not seen yet, in the kinds left to the digest, arrives in one email",
       %{account: account, bob: bob, alice: alice} do
    liked(alice, bob, "a post bob wrote")

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      assert [{_name, to}] = email.to
      assert to == address(account)
      # the range it covers, for a daily digest
      assert email.subject == "What happened today"

      # an intro, a header naming the persona, then what happened (the HTML escapes the apostrophe, the text part does not)
      assert email.html_body =~ "what happened on"
      assert email.text_body =~ "Here's what happened"
      assert email.html_body =~ "@#{bob.character.username}"
      assert email.html_body =~ "liked"
    end)
  end

  test "a kind set to Instant or Off is not in the digest", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    liked(alice, bob, "a post bob wrote")

    # Instant ones were emailed as they happened
    set(bob, [:notifications, :email, :react], true)
    assert {:ok, :nothing} = Digest.send_now(account)
    refute_email_sent()

    # and Off ones are never emailed
    set(bob, [:notifications, :email, :react], false)
    assert {:ok, :nothing} = Digest.send_now(account)
    refute_email_sent()
  end

  test "what was already seen in the feed is still in the digest", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    like = liked(alice, bob, "a post bob wrote")

    # as visiting the notifications page does
    Bonfire.Social.FeedActivities.mark_all_seen(
      Bonfire.Social.Feeds.my_feed_id(:notifications, bob),
      current_user: bob
    )

    # the positive first: it really is seen now, or this test would prove nothing
    assert Bonfire.Social.Seen.seen?(bob, e(like, :activity, nil) || like)

    assert {:ok, %Swoosh.Email{}} = Digest.send_now(account)
    assert_email_sent(fn email -> assert email.html_body =~ "liked" end)
  end

  test "nothing waiting sends nothing", %{account: account} do
    assert {:ok, :nothing} = Digest.send_now(account)
    refute_email_sent()
  end

  test "an account's personas share one email, each under its own header", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    other_persona = Bonfire.Me.Fake.fake_user!(account)

    liked(alice, bob, "a post bob wrote")
    liked(alice, other_persona, "a post the other persona wrote")

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      assert email.html_body =~ "@#{bob.character.username}"
      assert email.html_body =~ "@#{other_persona.character.username}"
    end)

    # one email for the account, not one per persona
    refute_email_sent()
  end

  describe "the schedule" do
    # a notification in a kind left to the digest queues the account's digest for when it is due, so only accounts with something waiting ever get one

    # a digest is Never until chosen, so each of these starts from someone who asked for a daily one
    setup %{bob: bob} do
      {:ok, bob: set(bob, [:notifications, :email_digest], :daily)}
    end

    test "nobody who has not chosen a frequency gets a digest queued", %{alice: alice} do
      account = Bonfire.Me.Fake.fake_account!()
      undecided = Bonfire.Me.Fake.fake_user!(account)
      notified(alice, undecided, "a post they wrote")

      assert [] = waiting_digests(account)
    end

    test "a notification left to the digest queues the account's digest a day out, once", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      notified(alice, bob, "a post bob wrote")
      notified(alice, bob, "another post bob wrote")

      assert [job] = waiting_digests(account)
      assert_about(job.scheduled_at, DateTime.add(DateTime.utc_now(), 1, :day))
    end

    test "a kind set to Instant or Off queues no digest", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      set(bob, [:notifications, :email, :react], true)
      notified(alice, bob, "a post bob wrote")
      assert [] = waiting_digests(account)

      set(bob, [:notifications, :email, :react], false)
      notified(alice, bob, "another post bob wrote")
      assert [] = waiting_digests(account)
    end

    test "a digest set to Never queues nothing", %{account: account, bob: bob, alice: alice} do
      set(bob, [:notifications, :email_digest], :never)
      notified(alice, bob, "a post bob wrote")

      assert [] = waiting_digests(account)
    end

    test "each digest covers what came since the one before", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      notified(alice, bob, "the first post")
      run_waiting_digests()

      assert_email_sent(fn email -> assert email.html_body =~ "the first post" end)

      notified(alice, bob, "the second post")

      # due a day after the last one went out
      assert [job] = waiting_digests(account)
      assert_about(job.scheduled_at, DateTime.add(DateTime.utc_now(), 1, :day))

      run_waiting_digests()

      # the refute first, since what this function returns is what `assert_email_sent/1` checks
      assert_email_sent(fn email ->
        refute email.html_body =~ "the first post"
        assert email.html_body =~ "the second post"
      end)
    end

    test "what came before a kind was left to the digest is not in it", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      # emailed as it happened, so it must not come again
      bob = set(bob, [:notifications, :email, :react], true)
      notified(alice, bob, "liked while instant")
      # the positive first: the switch did stop the digest being queued, and emailed it as it happened instead
      assert [] = waiting_digests(account)
      run_waiting_digests()
      assert_email_sent(fn email -> assert email.html_body =~ "liked while instant" end)

      bob = unset(bob, [:notifications, :email, :react])
      notified(alice, bob, "liked after the switch")
      run_waiting_digests()

      assert_email_sent(fn email ->
        refute email.html_body =~ "liked while instant"
        assert email.html_body =~ "liked after the switch"
      end)
    end

    test "what came while the digest was Never is not in the first one after", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      bob = set(bob, [:notifications, :email_digest], :never)
      notified(alice, bob, "liked while never")
      assert [] = waiting_digests(account)

      set(bob, [:notifications, :email_digest], :daily)
      notified(alice, bob, "liked once daily")
      run_waiting_digests()

      assert_email_sent(fn email ->
        refute email.html_body =~ "liked while never"
        assert email.html_body =~ "liked once daily"
      end)
    end

    test "a moved digest still starts from the notification that queued it", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      bob = set(bob, [:notifications, :email, :react], false)
      notified(alice, bob, "liked while off")

      bob = unset(bob, [:notifications, :email, :react])
      notified(alice, bob, "liked after the switch")

      bob = set(bob, [:notifications, :email_digest], :weekly)
      Digest.reschedule(bob)
      assert [_] = waiting_digests(account)

      run_waiting_digests()

      assert_email_sent(fn email ->
        refute email.html_body =~ "liked while off"
        assert email.html_body =~ "liked after the switch"
      end)
    end

    test "changing how often moves the waiting digest", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      notified(alice, bob, "a post bob wrote")
      assert [_] = waiting_digests(account)

      bob = set(bob, [:notifications, :email_digest], :weekly)
      Digest.reschedule(bob)

      assert [job] = waiting_digests(account)
      assert_about(job.scheduled_at, DateTime.add(DateTime.utc_now(), 7, :day))
    end

    test "changing it to Never cancels the waiting digest", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      notified(alice, bob, "a post bob wrote")
      assert [_] = waiting_digests(account)

      bob = set(bob, [:notifications, :email_digest], :never)
      Digest.reschedule(bob)

      assert [] = waiting_digests(account)
    end

    test "changing it with nothing waiting queues nothing", %{account: account, bob: bob} do
      bob = set(bob, [:notifications, :email_digest], :weekly)
      Digest.reschedule(bob)

      assert [] = waiting_digests(account)
    end
  end

  # a like, and the fan-out it queued (with whatever that delivers), run as the queue would, while a digest it queued stays waiting for its time
  defp notified(liker, author, text) do
    like = liked(liker, author, text)
    Oban.drain_queue(Bonfire.Common.TestInstanceRepo.oban_name(), queue: :notify)
    like
  end

  defp waiting_digests(account) do
    Oban.Testing.all_enqueued(Bonfire.Common.Repo, worker: Bonfire.Notify.Worker)
    |> Enum.filter(&(&1.args["op"] == "digest" and &1.args["account_id"] == account.id))
  end

  # as the queue would once they are due, so each is completed rather than left waiting
  defp run_waiting_digests do
    Oban.drain_queue(Bonfire.Common.TestInstanceRepo.oban_name(),
      queue: :notify,
      with_scheduled: true
    )
  end

  defp assert_about(at, expected) do
    assert abs(DateTime.diff(at, expected, :second)) < 60,
           "expected about #{expected}, got #{at}"
  end
end
