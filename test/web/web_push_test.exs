defmodule Bonfire.Notify.WebPushTest do
  use Bonfire.Notify.DataCase, async: true
  use Bonfire.Common.Repo

  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.WebPush
  alias Bonfire.Notify.WebPushDevice

  @valid_data %{
    "endpoint" => "https://endpoint.test",
    "keys" => %{
      "p256dh" => "test_p256dh",
      "auth" => "test_auth"
    }
  }

  defp device_of(user_sub), do: repo().get!(PushDevice, user_sub.push_device_id)

  describe "subscribe/2" do
    test "creates a new subscription from JSON string" do
      user = fake_user!()
      json_data = Jason.encode!(@valid_data)

      {:ok, user_sub} = WebPush.subscribe(user.id, json_data)

      # subscribing returns the person's subscription; what the browser sent is on the device
      assert user_sub.id == user.id
      assert user_sub.push_device_id

      device = device_of(user_sub)
      assert device.provider == :web
      assert device.address == "https://endpoint.test"
      assert device.auth_key == "test_auth"
      assert device.p256dh_key == "test_p256dh"
      assert device.active == true
    end

    test "creates a new subscription from map" do
      user = fake_user!()

      {:ok, user_sub} = WebPush.subscribe(user.id, @valid_data)

      assert device_of(user_sub).address == "https://endpoint.test"
    end

    test "returns the existing subscription on a duplicate endpoint for the same user" do
      user = fake_user!()

      {:ok, sub1} = WebPush.subscribe(user.id, @valid_data)
      original_device_id = sub1.push_device_id

      updated_data = put_in(@valid_data, ["keys", "auth"], "new_auth")
      {:ok, sub2} = WebPush.subscribe(user.id, updated_data)

      assert sub2.push_device_id == original_device_id
      assert device_of(sub2).auth_key == "new_auth"
    end

    test "allows multiple users to share the same endpoint" do
      user1 = fake_user!()
      user2 = fake_user!()

      {:ok, sub1} = WebPush.subscribe(user1.id, @valid_data)
      {:ok, sub2} = WebPush.subscribe(user2.id, @valid_data)

      # one device, a subscription each
      assert sub1.push_device_id == sub2.push_device_id
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

  describe "to_ex_nudge_subscription/2" do
    test "carries the endpoint, the browser's keys, and who it is for" do
      user = fake_user!()
      {:ok, user_sub} = WebPush.subscribe(user.id, @valid_data)

      sub = WebPushDevice.to_ex_nudge_subscription(device_of(user_sub), user.id)

      assert %ExNudge.Subscription{} = sub
      assert sub.endpoint == "https://endpoint.test"
      assert sub.keys.auth == "test_auth"
      assert sub.keys.p256dh == "test_p256dh"
      assert sub.metadata.user_id == user.id
    end
  end

  describe "list_subscriptions/1" do
    test "only returns subscriptions to devices that still work" do
      user = fake_user!()
      {:ok, user_sub} = WebPush.subscribe(user.id, @valid_data)

      assert [_] = WebPush.list_subscriptions([user.id])

      PushDevice.mark_status(device_of(user_sub), {:expired, :gone})

      assert [] = WebPush.list_subscriptions([user.id])
    end

    test "returns nothing for users with no subscriptions" do
      assert [] = WebPush.list_subscriptions([fake_user!().id])
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

      assert [_] = WebPush.list_subscriptions([user.id])

      WebPush.remove_subscription_by_endpoint("https://endpoint.test")

      assert [] = WebPush.list_subscriptions([user.id])
    end
  end
end
