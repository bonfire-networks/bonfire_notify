defmodule Bonfire.Notify.PostsTest do
  use Bonfire.Notify.DataCase, async: true

  import Ecto.Query
  import Bonfire.Me.Fake

  describe "notify/2" do
    test "attempt to send a notification to a user" do
      creator = fake_user!()
      notify_user = fake_user!()

      object = %{
        id: Needle.ULID.generate(),
        name: "Test Notification",
        summary: "Nice to meet you",
        creator: creator,
        canonical_url: "/test/123"
      }

      assert {:error, :no_subscriptions} = Bonfire.Notify.notify(object, notify_user)
    end

    test "attempts to send notifications to multiple users" do
      creator = fake_user!()
      user1 = fake_user!()
      user2 = fake_user!()

      object = %{
        id: Needle.ULID.generate(),
        name: "Test Notification",
        summary: "Hello everyone",
        creator: creator
      }

      assert {:error, :no_subscriptions} = Bonfire.Notify.notify(object, [user1, user2])
    end

    test "does not notify the creator" do
      creator = fake_user!()

      object = %{
        id: Needle.ULID.generate(),
        name: "Self Post",
        creator: creator
      }

      assert {:error, :no_valid_recipients} = Bonfire.Notify.notify(object, [creator])
    end
  end

  describe "format_push_message/3" do
    test "formats a push notification message" do
      creator = fake_user!()

      object = %{
        id: "test123",
        name: "Test Post",
        summary: "This is a test",
        canonical_url: "/posts/test123"
      }

      message = Bonfire.Notify.format_push_message(object, creator)
      data = Jason.decode!(message)

      assert data["title"] == "Test Post"
      assert data["body"] == "This is a test"
      assert data["data"]["url"] == "/posts/test123"
      assert data["tag"] == "test123"
    end
  end
end
