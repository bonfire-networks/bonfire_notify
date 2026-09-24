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

      # the activity's subject (who did what) carries when it happened, from its email template, which is what tells activities apart by day in a digest. The like was made just now
      assert email.html_body =~ Bonfire.Common.DatesTimes.format_date(Date.utc_today())
    end)
  end

  test "an email shows only what an email can: the page's buttons and menus are left out of both parts",
       %{alice: alice} do
    {bob, post} = author()
    set(bob, [:notifications, :email, :react], true)

    like_and_deliver(alice, bob, post)

    assert_email_sent(fn email ->
      # a component with no email template (the post's actions) is dropped, not named: no module name reaches the reader
      refute email.html_body =~ "Elixir."
      refute email.text_body =~ "Elixir."

      # and the row itself is there, with a whole address to it, since an email is read away from the instance (last, since `assert_email_sent/1` wants a truthy answer)
      assert email.html_body =~ "something worth liking"
      assert email.text_body =~ "something worth liking"
      assert email.text_body =~ Bonfire.Common.URIs.base_url() <> "/post/" <> post.id
    end)
  end

  test "under a like of your own post, no author line: it would only name you (or, wrongly, the liker)",
       %{alice: alice} do
    {bob, post} = author()
    set(bob, [:notifications, :email, :react], true)

    like_and_deliver(alice, bob, post)

    assert_email_sent(fn email ->
      for body <- [email.html_body, email.text_body] do
        # an author line reads "name - @username"; the line saying who liked it names nobody by username
        refute body =~ "@#{bob.character.username}"
        refute body =~ "@#{alice.character.username}"
      end

      assert email.text_body =~ "something worth liking"
    end)
  end

  test "who did it is shown with their avatar, at an address an inbox can load", %{alice: alice} do
    {bob, post} = author()
    set(bob, [:notifications, :email, :react], true)

    like_and_deliver(alice, bob, post)

    avatar =
      alice
      |> repo().preload(profile: :icon)
      |> Bonfire.Common.Media.avatar_url()
      |> Bonfire.UI.Common.SEOImage.absolute_url()

    assert_email_sent(fn email ->
      assert "http" <> _ = avatar
      assert avatar in (email.html_body |> Floki.parse_document!() |> Floki.attribute("img", "src"))
    end)
  end

  test "a post behind a content warning is emailed as its warning, not its text", %{alice: alice} do
    {bob, _post} = author()
    set(bob, [:notifications, :email, :react], true)

    {:ok, warned} =
      Bonfire.Posts.publish(
        current_user: bob,
        post_attrs: %{
          sensitive: true,
          post_content: %{summary: "a spoiler warning", html_body: "the secret ending"}
        },
        boundary: "public"
      )

    like_and_deliver(alice, bob, warned)

    assert_email_sent(fn email ->
      refute email.html_body =~ "the secret ending"
      refute email.text_body =~ "the secret ending"
      assert email.html_body =~ "a spoiler warning"
      assert email.text_body =~ "a spoiler warning"
    end)
  end

  test "a post marked sensitive without a warning of its own is still hidden, behind a generic one",
       %{alice: alice} do
    {bob, _post} = author()
    set(bob, [:notifications, :email, :react], true)

    {:ok, warned} =
      Bonfire.Posts.publish(
        current_user: bob,
        post_attrs: %{sensitive: true, post_content: %{html_body: "the secret ending"}},
        boundary: "public"
      )

    like_and_deliver(alice, bob, warned)

    assert_email_sent(fn email ->
      refute email.html_body =~ "the secret ending"
      refute email.text_body =~ "the secret ending"
      assert email.text_body =~ "Content warning"
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
