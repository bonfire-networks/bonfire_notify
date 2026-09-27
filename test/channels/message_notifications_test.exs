defmodule Bonfire.Notify.MessageNotificationsTest do
  @moduledoc """
  A direct message on each channel it can reach someone by: pushed to their browsers, emailed as it happens, or counted in the digest.

  Messages have a setting of their own, Messages, with its own Push and Email switches. They are not something "no category covers", so switching Other off to quiet votes and pins leaves them alone.

  A push says who wrote and not what, since it passes through a push service we don't run. An email goes to the reader's own address, so an instant one carries what was written. The digest says how many are waiting.

  Everything goes through `Bonfire.Messages.send/3` and the queue, run as it would run, since a message reaches the fan-out through its inbox rather than through anything a test could call directly.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E
  import Swoosh.TestAssertions

  alias Bonfire.Notify.WebPush

  setup do
    # as `Bonfire.Mailer.SwooshTest` does, so what is sent comes back to this process
    Process.put([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour], Bonfire.Mailer.Swoosh)
    on_exit(fn -> Process.delete([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour]) end)

    configure_web_push()

    account = Bonfire.Me.Fake.fake_account!()
    bob = Bonfire.Me.Fake.fake_user!(account)

    {:ok, _} =
      WebPush.subscribe(bob.id, valid_push_subscription_map("https://push.bonfire.local/bob"))

    # signing up can send mail of its own (asking to confirm the address), which is not what these tests are about
    flush_sent_emails()

    {:ok, account: account, bob: bob, alice: Bonfire.Me.Fake.fake_user!()}
  end

  # a message, and the fan-out and deliveries it queued, run as the queue would. A digest it queued stays waiting for its time
  defp message(from, to, text) do
    {:ok, message} = Bonfire.Messages.send(from, %{post_content: %{html_body: text}}, [to])
    run_queue()
    message
  end

  # recursing, since the fan-out queues the deliveries, and a drain otherwise runs only what was queued before it started
  defp run_queue,
    do:
      Oban.drain_queue(Bonfire.Common.TestInstanceRepo.oban_name(),
        queue: :notify,
        with_recursion: true
      )

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

  defp address(user) do
    Bonfire.Common.Repo.preload(user, accounted: [account: :email]).accounted.account.email.email_address
  end

  describe "push" do
    test "a message is pushed to its recipient, saying who wrote and nothing of what", %{
      bob: bob,
      alice: alice
    } do
      message(alice, bob, "the secret is the badger")

      assert_receive {:web_push_sent, _subscription, payload, _opts}
      assert inspect(payload) =~ "sent you a message"
      refute inspect(payload) =~ "badger"
    end

    test "switching Messages' Push off stops messages being pushed", %{bob: bob, alice: alice} do
      bob = set(bob, [:notifications, :push, :message], false)

      message(alice, bob, "a message bob asked not to be pushed")

      refute_receive {:web_push_sent, _, _, _}

      # while the rest still is, so the silence above is the switch and not a pipeline that never ran
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: bob,
          post_attrs: %{post_content: %{html_body: "something to like"}},
          boundary: "public"
        )

      {:ok, _} = Bonfire.Social.Likes.like(alice, post)
      run_queue()

      assert_receive {:web_push_sent, _, payload, _}
      assert inspect(payload) =~ "liked"
    end

    test "switching Other's Push off leaves messages pushed", %{bob: bob, alice: alice} do
      bob = set(bob, [:notifications, :push, :other], false)

      message(alice, bob, "a message, which is not something no category covers")

      assert_receive {:web_push_sent, _subscription, payload, _opts}
      assert inspect(payload) =~ "sent you a message"
    end
  end

  describe "email as it happens" do
    # unlike a push, which passes through a service we don't run, an email goes to the reader's own address, so it carries what was written
    test "Messages set to Immediately emails a message, with what was written", %{
      bob: bob,
      alice: alice
    } do
      bob = set(bob, [:notifications, :email, :message], true)

      message(alice, bob, "the secret is the badger")

      assert_email_sent(fn email ->
        assert [{_name, to}] = email.to
        assert to == address(bob)
        assert email.subject =~ "message"
        assert email.html_body =~ "badger"
        assert email.text_body =~ "badger"
      end)
    end

    test "Other set to Immediately does not email a message", %{bob: bob, alice: alice} do
      bob = set(bob, [:notifications, :email, :other], true)

      message(alice, bob, "a message left to its own setting")

      # the fan-out ran, so no email is the setting's answer rather than nothing having happened
      assert_receive {:web_push_sent, _, _, _}
      refute_email_sent()
    end
  end

  describe "digest" do
    test "with Messages left to the digest, it says how many messages are waiting, and nothing of what they say",
         %{account: account, bob: bob, alice: alice} do
      message(alice, bob, "the secret is the badger")
      message(alice, bob, "and the badger is in the garden")
      flush_sent_emails()

      assert {:ok, _} = Bonfire.Notify.Digest.send_now(account)

      assert_email_sent(fn email ->
        for body <- [email.html_body, email.text_body] do
          assert body =~ "2 new messages"
          refute body =~ "badger"
        end
      end)
    end
  end
end
