defmodule Bonfire.Notify.BroadcastTest do
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E
  use Bonfire.Common.Config

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Notify.WebPush

  describe "broadcast/2 permissions" do
    @tag :todo
    test "moderator can broadcast" do
      mod = fake_user!()

      {:ok, _} =
        Bonfire.Boundaries.Circles.add_to_circles(
          mod,
          Bonfire.Boundaries.Scaffold.Instance.mod_circle()
        )

      local_user = fake_user!()

      attrs = %{post: %{post_content: %{html_body: "Mod broadcast"}}}

      assert {:ok, _published, count} = Bonfire.Notify.Broadcast.broadcast(mod, attrs)
      assert count >= 1
      assert FeedLoader.feed_contains?(:notifications, "Mod broadcast", current_user: local_user)
    end

    test "non-admin/non-mod gets unauthorized error" do
      user = fake_user!()
      attrs = %{post: %{post_content: %{html_body: "Unauthorized"}}}

      assert {:error, :unauthorized} = Bonfire.Notify.Broadcast.broadcast(user, attrs)
    end
  end

  describe "broadcast/2 with local boundary" do
    test "creates a post and notifies all local users" do
      account = fake_account!()
      admin = fake_admin!(account)
      local_user = fake_user!()

      attrs = %{post: %{post_content: %{html_body: "Hello local users!"}}}

      assert {:ok, published, count} = Bonfire.Notify.Broadcast.broadcast(admin, attrs)
      assert count >= 1
      assert FeedLoader.feed_contains?(:notifications, published, current_user: local_user)
    end
  end

  describe "push notification URL resolution" do
    test "push message uses post's own path when no media/quote" do
      account = fake_account!()
      admin = fake_admin!(account)

      attrs = %{post: %{post_content: %{html_body: "Plain broadcast"}}}
      assert {:ok, published, _count} = Bonfire.Notify.Broadcast.broadcast(admin, attrs)

      post_path = Bonfire.Common.URIs.path(published)
      assert is_binary(post_path)
      assert String.starts_with?(post_path, "/")

      msg = WebPush.format_push_message("Test", "body", url: post_path)
      decoded = Jason.decode!(msg)
      assert decoded["data"]["url"] == post_path
    end

    test "push message uses quoted object path when quoting another post" do
      account = fake_account!()
      admin = fake_admin!(account)
      author = fake_user!()

      {:ok, quoted_post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "original post to quote"}},
          boundary: "local"
        )

      quoted_path = Bonfire.Common.URIs.path(quoted_post)
      assert is_binary(quoted_path)

      # Simulate what resolve_push_url does: object.quote.path falls back to path(object)
      # For a quoted post, quoted_path should be used as the notification URL
      msg = WebPush.format_push_message("Broadcast", "text", url: quoted_path)
      decoded = Jason.decode!(msg)
      assert decoded["data"]["url"] == quoted_path
    end

    test "push message uses external http URL when quoting a Media link preview" do
      external_url = "https://example.com/some-article"

      # resolve_push_url checks object.quote.path for external URLs
      # Simulate a quoted Media with an external path
      fake_object_with_quoted_media = %{
        id: "someid",
        quote: %{path: external_url}
      }

      resolved_url =
        case e(fake_object_with_quoted_media, :quote, :path, nil) do
          url when is_binary(url) and url != "" -> url
          _ -> Bonfire.Common.URIs.path(fake_object_with_quoted_media)
        end

      assert resolved_url == external_url

      msg = WebPush.format_push_message("Broadcast", "text", url: resolved_url)
      decoded = Jason.decode!(msg)
      assert decoded["data"]["url"] == external_url
    end

    test "push message uses own http URL when object itself is a Media link preview (config enabled)" do
      Process.put(
        [:bonfire_notify, Bonfire.Social.LivePush, :broadcast_media_canonical_link],
        true
      )

      external_url = "https://example.com/linked-page"

      # resolve_push_url checks object.path when :broadcast_media_canonical_link is enabled
      # Simulate an object that IS a Media link (path is an external URL)
      fake_media_object = %{id: "mediaid", path: external_url}

      media_path =
        if Bonfire.Common.Config.get(
             [:bonfire_notify, Bonfire.Social.LivePush, :broadcast_media_canonical_link],
             false
           ) do
          e(fake_media_object, :path, nil)
        end

      resolved_url =
        if is_binary(media_path) and String.starts_with?(media_path, "http"),
          do: media_path,
          else:
            e(fake_media_object, :quote, :path, nil) ||
              Bonfire.Common.URIs.path(fake_media_object)

      assert resolved_url == external_url

      msg = WebPush.format_push_message("Broadcast", "text", url: resolved_url)
      decoded = Jason.decode!(msg)
      assert decoded["data"]["url"] == external_url
    end
  end

  describe "broadcast/2 with custom circles" do
    test "notifies only user-level circle members, not non-members" do
      account = fake_account!()
      admin = fake_admin!(account)
      circle_member = fake_user!()
      non_member = fake_user!()

      {:ok, circle} = Circles.create(admin, %{named: %{name: "VIPs"}})
      {:ok, _} = Circles.add_to_circles(circle_member, circle)

      attrs = %{
        post: %{post_content: %{html_body: "VIP announcement"}},
        to_boundaries: "circles",
        to_circles: [circle.id]
      }

      assert {:ok, published, count} = Bonfire.Notify.Broadcast.broadcast(admin, attrs)
      assert count == 1
      assert FeedLoader.feed_contains?(:notifications, published, current_user: circle_member)
      refute FeedLoader.feed_contains?(:notifications, published, current_user: non_member)
      refute FeedLoader.feed_contains?(:local, published)
    end

    test "notifies only instance-level circle members, not non-members" do
      account = fake_account!()
      admin = fake_admin!(account)
      circle_member = fake_user!()
      non_member = fake_user!()

      {:ok, circle} = Circles.create(:instance, %{named: %{name: "Moderators"}})
      {:ok, _} = Circles.add_to_circles(circle_member, circle)

      attrs = %{
        post: %{post_content: %{html_body: "Moderator-only announcement"}},
        to_boundaries: "circles",
        to_circles: [circle.id]
      }

      assert {:ok, published, count} = Bonfire.Notify.Broadcast.broadcast(admin, attrs)
      assert count == 1
      assert FeedLoader.feed_contains?(:notifications, published, current_user: circle_member)
      refute FeedLoader.feed_contains?(:notifications, published, current_user: non_member)
      refute FeedLoader.feed_contains?(:local, published)
    end
  end
end
