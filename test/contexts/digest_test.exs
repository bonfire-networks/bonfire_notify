defmodule Bonfire.Notify.DigestTest do
  @moduledoc """
  The digest: one email per account, with what reached each of its personas in its window, in the kinds they left to the digest, whether or not it was already seen in the feed.

  A kind's Email setting is Off (`false`), Digest (unset) or Instant (`true`). Instant kinds were already emailed as they happened and Off ones never are, so only the Digest ones go in. An account with nothing waiting gets no email at all.

  Sent here with `Bonfire.Notify.Digest.send_now/2`, which is what the admin's "Send me a test digest" button calls, and what the schedule will call for each account that is due.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E
  use Arrows
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

  # the post a like from `liked/3` is about
  defp liked_post_id(like), do: e(like, :edge, :object_id, nil)

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

  # how often the digest comes is the account's choice, since the digest is one email per account. Returns the account as it now is, which is what a caller hands on
  defp set_frequency(account, frequency),
    do:
      Bonfire.Common.Settings.put([:notifications, :email_digest], frequency,
        current_account: account,
        scope: :account
      )
      ~> Bonfire.Common.Utils.current_account()

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

      # an intro saying from when (the first digest looks back a week), a header naming the persona, then what happened
      since = "Since " <> Bonfire.Common.DatesTimes.format_date(Date.add(Date.utc_today(), -7))
      assert email.html_body =~ since
      assert email.text_body =~ since
      assert email.html_body =~ "@#{bob.character.username}"
      # a component with no email template (the post's actions) is dropped, not named: no module name reaches the reader
      refute email.html_body =~ "Elixir."

      assert email.html_body =~ "liked"
    end)
  end

  test "each row carries its text and a whole link to it, in both parts", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    post_id = alice |> liked(bob, "a post bob wrote") |> liked_post_id()
    # a whole address, since an email is read away from the instance
    link = Bonfire.Common.URIs.base_url() <> "/post/" <> post_id

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      assert email.text_body =~ "a post bob wrote"
      assert email.text_body =~ link
      assert email.html_body =~ "a post bob wrote"
      assert email.html_body =~ ~s(href="#{link}")
    end)
  end

  test "each notification is a block of its own, and each part of it a line of its own", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    liked(alice, bob, "the first post")
    liked(alice, bob, "the second post")

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      doc = Floki.parse_document!(email.html_body)

      # the smallest element holding some text is the line it sits on
      line_of = fn text ->
        doc
        |> Floki.find("div, p, td")
        |> Enum.filter(&(Floki.text(&1) =~ text))
        |> Enum.min_by(&String.length(Floki.text(&1)))
        |> Floki.text()
      end

      # two notifications do not share a line, nor does a post share one with what was done to it
      refute line_of.("the first post") =~ "the second post"
      refute line_of.("the first post") =~ "liked your activity"
      assert line_of.("the first post") =~ "the first post"
    end)
  end

  test "each notification says what happened to the reader, as the notifications feed does",
       %{account: account, bob: bob, alice: alice} do
    post_id = alice |> liked(bob, "a post bob wrote") |> liked_post_id()

    {:ok, _} =
      Bonfire.Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "an answer"}, reply_to_id: post_id},
        boundary: "public"
      )

    {:ok, _} = Bonfire.Social.Graph.Follows.follow(alice, bob)
    flush_sent_emails()

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      # in the text part too, what was done and who wrote it are lines of their own
      replied_line =
        email.text_body |> String.split("\n") |> Enum.find(&(&1 =~ "replied to you"))

      refute replied_line =~ "@#{alice.character.username}"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "replied to you"
        assert body =~ "followed you"
        assert body =~ "liked"
        # the reply's author line names who wrote it, since that is not the reader
        assert body =~ "@#{alice.character.username}"
      end
    end)
  end

  test "a request to join a group they run reads as one, not as a follow", %{
    account: account,
    bob: bob
  } do
    group = Bonfire.Classify.Simulate.fake_group!(bob, %{membership: "on_request"})
    asker = Bonfire.Me.Fake.fake_user!("Only Joining")
    {:ok, %{requested: true}} = Bonfire.Classify.Categories.join_group(asker, group)
    flush_sent_emails()

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      refute email.text_body =~ "requested to follow"
      assert email.html_body =~ "requested to join"
      assert email.text_body =~ "Only Joining requested to join"
    end)
  end

  test "the email says where to read everything, and where to change what it sends", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    liked(alice, bob, "a post bob wrote")

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      base = Bonfire.Common.URIs.base_url()

      for body <- [email.html_body, email.text_body] do
        assert body =~ base <> "/notifications"
        assert body =~ base <> "/settings/user/bonfire_notify"
      end
    end)
  end

  test "the digest wears the instance's email theme, with a title saying what it covers", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    liked(alice, bob, "a post bob wrote")

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      # the same theme the account emails use (`[:ui, :auth, :email_theme]`)
      assert email.html_body =~ Bonfire.UI.Common.Email.Basic.theme()[:primary]
      # the title is in the body, not only in the subject
      assert email.html_body =~ email.subject
      assert email.text_body =~ email.subject
    end)
  end

  test "a long post comes as an excerpt, so one post cannot fill the email", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    liked(
      alice,
      bob,
      "The opening sentence. " <>
        String.duplicate("Some words that carry on. ", 40) <> "The closing sentence."
    )

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      refute email.html_body =~ "The closing sentence"
      refute email.text_body =~ "The closing sentence"
      assert email.html_body =~ "The opening sentence."
      assert email.text_body =~ "The opening sentence."
    end)
  end

  test "a post behind a content warning is in the digest as its warning, not its text", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    {:ok, warned} =
      Bonfire.Posts.publish(
        current_user: bob,
        post_attrs: %{
          sensitive: true,
          post_content: %{summary: "a spoiler warning", html_body: "the secret ending"}
        },
        boundary: "public"
      )

    {:ok, _} = Bonfire.Social.Likes.like(alice, warned)
    flush_sent_emails()

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      refute email.html_body =~ "the secret ending"
      refute email.text_body =~ "the secret ending"
      assert email.html_body =~ "a spoiler warning"
      assert email.text_body =~ "a spoiler warning"
    end)
  end

  test "the digest is in the language of the account's first persona", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    # French, because the test env compiles only en, fr, es and it. Told apart by how a date is written, which every locale has, rather than by a phrase whose translation may be missing
    set(bob, [Bonfire.Common.Localise.Cldr, :default_locale], "fr")
    liked(alice, bob, "a post bob wrote")

    today_in = fn locale ->
      Bonfire.Notify.Deliveries.in_locale(locale, fn ->
        Bonfire.Common.DatesTimes.format_date(Date.utc_today())
      end)
    end

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      refute email.text_body =~ today_in.("en")
      assert email.text_body =~ today_in.("fr")
    end)

    # and whatever runs next in this process has the language it had
    refute Bonfire.Common.Localise.get_locale_id() == :fr
  end

  test "a post's own characters come through as written, not as HTML entities", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    liked(alice, bob, "Q&A tonight: 1 < 2")

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      assert email.text_body =~ "Q&A tonight: 1 < 2"
      # escaped once, as HTML must be, and not twice
      refute email.html_body =~ "&amp;amp;"
      assert email.html_body =~ "Q&amp;A tonight: 1 &lt; 2"
    end)
  end

  test "a long post with no spaces (as in Japanese) still comes as an excerpt", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    liked(alice, bob, String.duplicate("語", 300))

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      refute email.text_body =~ String.duplicate("語", 300)
      assert email.text_body =~ String.duplicate("語", 100)
    end)
  end

  test "a theme that sets only some colours keeps the defaults for the rest", %{
    account: account,
    bob: bob,
    alice: alice
  } do
    Process.put([:bonfire, :ui, :auth, :email_theme], primary: "#123456")
    on_exit(fn -> Process.delete([:bonfire, :ui, :auth, :email_theme]) end)
    liked(alice, bob, "a post bob wrote")

    assert {:ok, _} = Digest.send_now(account)

    assert_email_sent(fn email ->
      # what it leaves out (here the muted text and the button's text) is still coloured
      refute email.html_body =~ ~r/color:\s*;/
      assert email.html_body =~ "#123456"
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

    # a digest is Never until chosen, so each of these starts from an account that asked for a daily one
    setup %{account: account} do
      set_frequency(account, :daily)
      :ok
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
      set_frequency(account, :never)
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
      set_frequency(account, :never)
      notified(alice, bob, "liked while never")
      assert [] = waiting_digests(account)

      set_frequency(account, :daily)
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

      Digest.reschedule(set_frequency(account, :weekly))
      assert [_] = waiting_digests(account)

      run_waiting_digests()

      assert_email_sent(fn email ->
        refute email.html_body =~ "liked while off"
        assert email.html_body =~ "liked after the switch"
      end)
    end

    test "how often is the account's choice, even where a persona has an old choice of its own",
         %{
           account: account,
           bob: bob,
           alice: alice
         } do
      # a choice saved on the persona before the frequency was per account
      set(bob, [:notifications, :email_digest], :daily)
      set_frequency(account, :weekly)

      notified(alice, bob, "a post bob wrote")

      assert [job] = waiting_digests(account)
      assert_about(job.scheduled_at, DateTime.add(DateTime.utc_now(), 7, :day))

      run_waiting_digests()
      assert_email_sent(fn email -> assert email.subject == "What happened this week" end)
    end

    test "changing how often moves the waiting digest", %{
      account: account,
      bob: bob,
      alice: alice
    } do
      notified(alice, bob, "a post bob wrote")
      assert [_] = waiting_digests(account)

      Digest.reschedule(set_frequency(account, :weekly))

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

      Digest.reschedule(set_frequency(account, :never))

      assert [] = waiting_digests(account)
    end

    test "changing it with nothing waiting queues nothing", %{account: account} do
      Digest.reschedule(set_frequency(account, :weekly))

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
