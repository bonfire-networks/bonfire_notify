defmodule Bonfire.Notify.AdminBroadcastUITest do
  use Bonfire.Notify.ConnCase, async: false

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Boundaries.Circles

  defp submit_announcement(session, content, extra_params \\ %{}) do
    session
    |> PhoenixTest.unwrap(fn view ->
      Phoenix.LiveViewTest.render_submit(
        view,
        "Bonfire.Notify:broadcast",
        Map.merge(
          %{
            "post" => %{"post_content" => %{"html_body" => content}},
            "to_boundaries" => ["local"]
          },
          extra_params
        )
      )
    end)
  end

  describe "admin broadcast widget" do
    test "admin sees the Compose Announcement button" do
      account = fake_account!()
      admin = fake_admin!(account)

      conn(user: admin, account: account)
      |> visit("/settings/instance/bonfire_notify")
      |> assert_has("button", text: "Compose Announcement")
    end

    test "button is wired to the announcement handler" do
      account = fake_account!()
      admin = fake_admin!(account)

      conn(user: admin, account: account)
      |> visit("/settings/instance/bonfire_notify")
      |> assert_has("#admin_broadcast_button[phx-click*='broadcast']")
    end

    test "non-admin does not see the Compose Announcement button" do
      account = fake_account!()
      user = fake_user!(account)

      conn(user: user, account: account)
      |> visit("/settings/instance/bonfire_notify")
      |> refute_has("button", text: "Compose Announcement")
    end

    test "non-admin gets an error when submitting the announce event directly" do
      account = fake_account!()
      user = fake_user!(account)
      local_user = fake_user!()

      content = "Unauthorized announcement #{System.unique_integer()}"

      conn(user: user, account: account)
      |> visit("/settings/instance/bonfire_notify")
      |> submit_announcement(content)
      |> assert_has("[role=alert]", text: "Could not send")

      refute FeedLoader.feed_contains?(:notifications, content, current_user: local_user)
    end

    test "admin can send an announcement that appears in local user's notifications" do
      account = fake_account!()
      admin = fake_admin!(account)
      local_user = fake_user!()

      content = "Important instance announcement #{System.unique_integer()}"

      conn(user: admin, account: account)
      |> visit("/settings/instance/bonfire_notify")
      |> submit_announcement(content)
      |> assert_has("[role=alert]", text: "Announcement sent")

      assert FeedLoader.feed_contains?(:notifications, content, current_user: local_user)

      conn(user: local_user)
      |> visit("/notifications")
      |> assert_has("[data-id=feed]", text: content)
      |> refute_has("[data-role=notification_subject]", text: "mentioned you")
    end

    test "circle-targeted announcement reaches member but not non-member" do
      account = fake_account!()
      admin = fake_admin!(account)
      circle_member = fake_user!()
      non_member = fake_user!()

      {:ok, circle} = Circles.create(admin, %{named: %{name: "VIPs #{System.unique_integer()}"}})
      {:ok, _} = Circles.add_to_circles(circle_member, circle)

      content = "VIP announcement #{System.unique_integer()}"

      conn(user: admin, account: account)
      |> visit("/settings/instance/bonfire_notify")
      |> submit_announcement(content, %{
        "to_boundaries" => ["circles"],
        "to_circles" => [circle.id]
      })
      |> assert_has("[role=alert]", text: "Announcement sent")

      assert FeedLoader.feed_contains?(:notifications, content, current_user: circle_member)
      refute FeedLoader.feed_contains?(:notifications, content, current_user: non_member)
    end

    test "instance-level circle announcement reaches member but not non-member" do
      account = fake_account!()
      admin = fake_admin!(account)
      circle_member = fake_user!()
      non_member = fake_user!()

      {:ok, circle} =
        Circles.create(:instance, %{named: %{name: "Mods #{System.unique_integer()}"}})

      {:ok, _} = Circles.add_to_circles(circle_member, circle)

      content = "Moderator announcement #{System.unique_integer()}"

      conn(user: admin, account: account)
      |> visit("/settings/instance/bonfire_notify")
      |> submit_announcement(content, %{
        "to_boundaries" => ["circles"],
        "to_circles" => [circle.id]
      })
      |> assert_has("[role=alert]", text: "Announcement sent")

      assert FeedLoader.feed_contains?(:notifications, content, current_user: circle_member)
      refute FeedLoader.feed_contains?(:notifications, content, current_user: non_member)
    end
  end

  describe "Send notification from boost/quote dropdown" do
    test "admin sees Send notification button on a post" do
      account = fake_account!()
      admin = fake_admin!(account)
      author = fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "original post"}},
          boundary: "local"
        )

      conn(user: admin, account: account)
      |> visit("/post/#{post.id}")
      |> assert_has("[data-role=broadcast_enabled]")
    end

    test "non-admin does not see Send notification button" do
      account = fake_account!()
      user = fake_user!(account)
      author = fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "original post"}},
          boundary: "local"
        )

      conn(user: user, account: account)
      |> visit("/post/#{post.id}")
      |> refute_has("[data-role=broadcast_enabled]")
    end
  end
end
