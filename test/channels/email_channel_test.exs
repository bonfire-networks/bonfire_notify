defmodule Bonfire.Notify.EmailChannelTest do
  @moduledoc """
  Email as a delivery channel, for the kinds of notification someone asked to be emailed about as they happen.

  Each category's Email setting is Off (`false`), In the digest (unset) or Immediately (`true`), and only Immediately is sent from here. The digest is the default, so a new kind of notification never starts sending one email each for everybody.

  A delivery is queued like a push, because sending is what fails and a job is what retries it, so each test runs the queued jobs and then looks at what was sent.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E
  import Swoosh.TestAssertions
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.FanOut
  alias Bonfire.Notify.Worker

  setup do
    # as `Bonfire.Mailer.SwooshTest` does, so what is sent comes back to this process
    Process.put([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour], Bonfire.Mailer.Swoosh)
    on_exit(fn -> Process.delete([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour]) end)

    alice = Bonfire.Me.Fake.fake_user!()

    {:ok, alice: alice}
  end

  defp author(account_opts \\ []) do
    account = Bonfire.Me.Fake.fake_account!(%{}, account_opts)
    user = Bonfire.Me.Fake.fake_user!(account)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "something worth liking"}},
        boundary: "public"
      )

    # signing up can send mail of its own (asking to confirm the address), which is not what these tests are about
    flush_sent_emails()

    {user, post}
  end

  defp flush_sent_emails do
    receive do
      {:email, _} -> flush_sent_emails()
    after
      0 -> :ok
    end
  end

  defp set(user, keys, value),
    do: Bonfire.Common.Settings.put(keys, value, current_user: user)

  defp like_and_deliver(alice, bob, post) do
    {:ok, like} = Bonfire.Social.Likes.like(alice, post)

    FanOut.notify(e(like, :activity, nil), %{
      recipients: [%{"user_id" => bob.id}],
      feeds: []
    })

    # the queued deliveries, run as the queue would
    for job <- Oban.Testing.all_enqueued(Bonfire.Common.Repo, worker: Worker),
        job.args["op"] == "deliver" do
      # a delivery that failed would otherwise just read as "nothing was sent"
      assert :ok = Worker.perform(job)
    end
  end

  defp address(user) do
    repo().preload(user, accounted: [account: :email]).accounted.account.email.email_address
  end

  test "the email channel is offered when the mailer can send" do
    assert {:email, Bonfire.Notify.Email} in Bonfire.Notify.Channel.configured()
  end

  test "a category set to Immediately is emailed as it happens", %{alice: alice} do
    {bob, post} = author()
    set(bob, [:notifications, :email, :react], true)

    like_and_deliver(alice, bob, post)

    assert_email_sent(fn email ->
      assert [{_name, to}] = email.to
      assert to == address(bob)
      assert email.subject =~ "liked"

      # the activity as the feed shows it, through its email template: MJML renders a whole HTML document
      assert email.html_body =~ "<!doctype html>"
      assert email.html_body =~ "something worth liking"
    end)
  end

  test "with nothing chosen a category waits for the digest, so nothing is emailed right away",
       %{alice: alice} do
    {bob, post} = author()

    like_and_deliver(alice, bob, post)

    refute_email_sent()
  end

  test "Immediately is per category: another category's says nothing about this one", %{
    alice: alice
  } do
    {bob, post} = author()
    set(bob, [:notifications, :email, :mention], true)

    like_and_deliver(alice, bob, post)

    refute_email_sent()
  end

  test "Other's choice covers what no category does, and leaves an untouched category to the digest",
       %{alice: alice} do
    {bob, post} = author()
    set(bob, [:notifications, :email, :other], true)

    like_and_deliver(alice, bob, post)

    refute_email_sent()
  end

  test "a category set to Off is not emailed", %{alice: alice} do
    {bob, post} = author()
    set(bob, [:notifications, :email, :react], false)

    like_and_deliver(alice, bob, post)

    refute_email_sent()
  end

  test "an address nobody confirmed is not emailed", %{alice: alice} do
    {bob, post} = author(must_confirm?: true)
    set(bob, [:notifications, :email, :react], true)

    like_and_deliver(alice, bob, post)

    refute_email_sent()
  end
end
