defmodule Bonfire.Notify.TestDigestButtonTest do
  @moduledoc """
  "Send me a test digest": in the notification settings, for instance admins only, it sends the admin their own digest now, covering the last 30 days, so its look can be checked without waiting for the schedule.
  """
  use Bonfire.Notify.ConnCase, async: false

  import Swoosh.TestAssertions

  setup do
    Process.put([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour], Bonfire.Mailer.Swoosh)
    on_exit(fn -> Process.delete([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour]) end)
    :ok
  end

  test "an admin sees it, and it sends them their digest" do
    account = fake_account!()
    admin = fake_admin!(account)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: admin,
        post_attrs: %{post_content: %{html_body: "something of the admin's"}},
        boundary: "public"
      )

    {:ok, _} = Bonfire.Social.Likes.like(fake_user!(), post)

    conn(user: admin, account: account)
    |> visit("/settings/user/bonfire_notify")
    |> click_button("#send_test_digest", "Send me a test digest")
    |> assert_has("[role=alert]", text: "Test digest sent")

    assert_email_sent(fn email -> assert email.subject =~ "new notification" end)
  end

  test "anyone else does not see it" do
    account = fake_account!()
    user = fake_user!(account)

    conn(user: user, account: account)
    |> visit("/settings/user/bonfire_notify")
    # the positive first: this is the page the button would be on
    |> assert_has("#notification-preferences-panel")
    |> refute_has("#send_test_digest")
  end
end
