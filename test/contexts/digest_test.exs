defmodule Bonfire.Notify.DigestTest do
  @moduledoc """
  The digest: one email per account, with what each of its personas has not seen yet in the kinds they left to the digest.

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

    {:ok, _} = Bonfire.Social.Likes.like(liker, post)
    flush_sent_emails()
  end

  # signing up can send mail of its own (asking to confirm the address), which is not what these tests are about
  defp flush_sent_emails do
    receive do
      {:email, _} -> flush_sent_emails()
    after
      0 -> :ok
    end
  end

  defp set(user, keys, value), do: Bonfire.Common.Settings.put(keys, value, current_user: user)

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
      # the count and the range it covers, for a daily digest
      assert email.subject =~ "1"
      assert email.subject =~ "today"

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
end
