defmodule Bonfire.Notify.WebPushTest do
  use Bonfire.Notify.DataCase, async: true
  use Bonfire.Common.Repo

  import Bonfire.Me.Fake
  alias Bonfire.Notify.WebPush
  alias Bonfire.Notify.UserSubscription

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

      {:ok, subscription} = WebPush.subscribe(user.id, json_data)

      assert subscription.user_id == user.id
      assert subscription.endpoint == "https://endpoint.test"
      assert subscription.auth_key == "test_auth"
      assert subscription.p256dh_key == "test_p256dh"
      assert subscription.active == true
    end

    test "creates a new subscription from map" do
      user = fake_user!()

      {:ok, subscription} = WebPush.subscribe(user.id, @valid_data)

      assert subscription.endpoint == "https://endpoint.test"
    end

    test "updates existing subscription on conflict" do
      user = fake_user!()

      {:ok, sub1} = WebPush.subscribe(user.id, @valid_data)
      original_id = sub1.id

      # Update with new keys
      updated_data = put_in(@valid_data, ["keys", "auth"], "new_auth")
      {:ok, sub2} = WebPush.subscribe(user.id, updated_data)

      assert sub2.id == original_id
      assert sub2.auth_key == "new_auth"
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
      {:ok, sub} = WebPush.subscribe(user.id, @valid_data)

      # Mark as inactive
      sub
      |> UserSubscription.mark_expired()
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
end
