defmodule Bonfire.Notify.WebPushTest do
  use Bonfire.Notify.DataCase, async: true
  use Bonfire.Common.Repo

  import Bonfire.Me.Fake
  alias Bonfire.Notify.WebPush
  alias Bonfire.Notify.PushSubscription

  @valid_data %{
    "endpoint" => "https://endpoint.test",
    "keys" => %{
      "p256dh" => "test_p256dh",
      "auth" => "test_auth"
    }
  }

  describe "subscribe/2" do
    test "creates a new subscription from JSON string" do
      user = fake_user!()
      json_data = Jason.encode!(@valid_data)

      {:ok, user_sub} = WebPush.subscribe(user.id, json_data)

      # subscribe returns a UserPushSubscription; device data is on PushSubscription
      assert user_sub.id == user.id
      assert user_sub.push_subscription_id

      push_sub = repo().get!(PushSubscription, user_sub.push_subscription_id)
      assert push_sub.endpoint == "https://endpoint.test"
      assert push_sub.auth_key == "test_auth"
      assert push_sub.p256dh_key == "test_p256dh"
      assert push_sub.active == true
    end

    test "creates a new subscription from map" do
      user = fake_user!()

      {:ok, user_sub} = WebPush.subscribe(user.id, @valid_data)

      push_sub = repo().get!(PushSubscription, user_sub.push_subscription_id)
      assert push_sub.endpoint == "https://endpoint.test"
    end

    test "returns existing link on duplicate endpoint for same user" do
      user = fake_user!()

      {:ok, sub1} = WebPush.subscribe(user.id, @valid_data)
      original_push_sub_id = sub1.push_subscription_id

      # Update with new keys
      updated_data = put_in(@valid_data, ["keys", "auth"], "new_auth")
      {:ok, sub2} = WebPush.subscribe(user.id, updated_data)

      # Same user link to the same push subscription
      assert sub2.push_subscription_id == original_push_sub_id

      # PushSubscription keys should be updated
      push_sub = repo().get!(PushSubscription, original_push_sub_id)
      assert push_sub.auth_key == "new_auth"
    end

    test "allows multiple users to share the same endpoint" do
      user1 = fake_user!()
      user2 = fake_user!()

      {:ok, sub1} = WebPush.subscribe(user1.id, @valid_data)
      {:ok, sub2} = WebPush.subscribe(user2.id, @valid_data)

      # Both link to the same PushSubscription
      assert sub1.push_subscription_id == sub2.push_subscription_id
      # But different users
      assert sub1.id == user1.id
      assert sub2.id == user2.id
    end

    test "returns error for invalid JSON" do
      user = fake_user!()

      assert {:error, :invalid_json} = WebPush.subscribe(user.id, "{invalid")
    end

    test "returns changeset error for invalid data structure" do
      user = fake_user!()

      assert {:error, %Ecto.Changeset{}} = WebPush.subscribe(user.id, %{"invalid" => "data"})
    end
  end

  describe "get_subscriptions/1" do
    test "returns subscriptions in ExNudge format" do
      user = fake_user!()
      {:ok, _} = WebPush.subscribe(user.id, @valid_data)

      subscriptions = WebPush.get_subscriptions([user.id])

      assert %{} = subscriptions
      assert [%ExNudge.Subscription{} = sub] = subscriptions[user.id]
      assert sub.endpoint == "https://endpoint.test"
      assert sub.keys.auth == "test_auth"
      assert sub.keys.p256dh == "test_p256dh"
      assert sub.metadata.user_id == user.id
    end

    test "only returns active subscriptions" do
      user = fake_user!()
      {:ok, user_sub} = WebPush.subscribe(user.id, @valid_data)

      # Mark the PushSubscription as inactive
      push_sub = repo().get!(PushSubscription, user_sub.push_subscription_id)

      push_sub
      |> PushSubscription.mark_expired()
      |> repo().update!()

      subscriptions = WebPush.get_subscriptions([user.id])
      assert subscriptions == %{}
    end

    test "returns empty map for users with no subscriptions" do
      user = fake_user!()
      assert %{} = WebPush.get_subscriptions([user.id])
    end
  end

  describe "format_push_message/3" do
    test "formats message as JSON" do
      json = WebPush.format_push_message("Test Title", "Test Body")
      data = Jason.decode!(json)

      assert data["title"] == "Test Title"
      assert data["body"] == "Test Body"
      assert data["requireInteraction"] == false
    end

    test "includes optional fields" do
      json =
        WebPush.format_push_message("Title", "Body",
          tag: "test_tag",
          url: "/test/url",
          require_interaction: true
        )

      data = Jason.decode!(json)

      assert data["tag"] == "test_tag"
      assert data["requireInteraction"] == true
      assert data["data"]["url"] == "/test/url"
    end
  end

  describe "remove_subscription_by_endpoint/1" do
    test "removes subscription by endpoint" do
      user = fake_user!()
      {:ok, _} = WebPush.subscribe(user.id, @valid_data)

      assert %{} != WebPush.get_subscriptions([user.id])

      WebPush.remove_subscription_by_endpoint("https://endpoint.test")

      assert %{} = WebPush.get_subscriptions([user.id])
    end
  end

  describe "resolve_feed_ids_to_user_ids/1" do
    test "resolves notification feed IDs to user IDs" do
      user = fake_user!()

      # Get the user's notification feed ID
      user_with_character = repo().preload(user, :character)
      notifications_id = user_with_character.character.notifications_id

      # Skip if no notifications_id (shouldn't happen with fake_user but just in case)
      if notifications_id do
        resolved_ids = WebPush.resolve_feed_ids_to_user_ids([notifications_id])
        assert user.id in resolved_ids
      end
    end

    test "returns empty list for non-existent feed IDs" do
      fake_feed_id = Needle.ULID.generate()
      assert [] = WebPush.resolve_feed_ids_to_user_ids([fake_feed_id])
    end
  end

  describe "send_web_push/3 with feed IDs" do
    test "finds subscriptions when given notification feed IDs instead of user IDs" do
      user = fake_user!()

      # Create a subscription for the user
      {:ok, _} = WebPush.subscribe(user.id, @valid_data)

      # Get the user's notification feed ID
      user_with_character = repo().preload(user, :character)
      notifications_id = user_with_character.character.notifications_id

      if notifications_id do
        message = WebPush.format_push_message("Test", "Message")

        # This should resolve the feed ID to the user ID and find the subscription
        # It will return an error from ExNudge since we're using a test endpoint,
        # but that's expected - we're testing the resolution logic
        result = WebPush.send_web_push([notifications_id], message)

        # Should not be :no_subscriptions since we have a subscription
        # (it might be an error from the actual push, but that's OK)
        refute result == {:error, :no_subscriptions}
      end
    end
  end
end
