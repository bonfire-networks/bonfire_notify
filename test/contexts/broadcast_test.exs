defmodule Bonfire.Notify.BroadcastTest do
  use Bonfire.Notify.DataCase, async: false

  import Bonfire.Me.Fake

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Social.FeedLoader

  describe "announce/2 with local boundary" do
    test "creates a post and notifies all local users" do
      account = fake_account!()
      admin = fake_user!(account)
      local_user = fake_user!()

      attrs = %{post: %{post_content: %{html_body: "Hello local users!"}}}

      assert {:ok, published, count} = Bonfire.Notify.Broadcast.announce(admin, attrs)
      assert count >= 1
      assert FeedLoader.feed_contains?(:notifications, published, current_user: local_user)
    end
  end

  describe "announce/2 with custom circles" do
    test "notifies only user-level circle members, not non-members" do
      account = fake_account!()
      admin = fake_user!(account)
      circle_member = fake_user!()
      non_member = fake_user!()

      {:ok, circle} = Circles.create(admin, %{named: %{name: "VIPs"}})
      {:ok, _} = Circles.add_to_circles(circle_member, circle)

      attrs = %{
        post: %{post_content: %{html_body: "VIP announcement"}},
        to_boundaries: "circles",
        to_circles: [circle.id]
      }

      assert {:ok, published, count} = Bonfire.Notify.Broadcast.announce(admin, attrs)
      assert count == 1
      assert FeedLoader.feed_contains?(:notifications, published, current_user: circle_member)
      refute FeedLoader.feed_contains?(:notifications, published, current_user: non_member)
      refute FeedLoader.feed_contains?(:local, published)
    end

    test "notifies only instance-level circle members, not non-members" do
      account = fake_account!()
      admin = fake_user!(account)
      circle_member = fake_user!()
      non_member = fake_user!()

      {:ok, circle} = Circles.create(:instance, %{named: %{name: "Moderators"}})
      {:ok, _} = Circles.add_to_circles(circle_member, circle)

      attrs = %{
        post: %{post_content: %{html_body: "Moderator-only announcement"}},
        to_boundaries: "circles",
        to_circles: [circle.id]
      }

      assert {:ok, published, count} = Bonfire.Notify.Broadcast.announce(admin, attrs)
      assert count == 1
      assert FeedLoader.feed_contains?(:notifications, published, current_user: circle_member)
      refute FeedLoader.feed_contains?(:notifications, published, current_user: non_member)
      refute FeedLoader.feed_contains?(:local, published)
    end
  end
end
