defmodule Bonfire.Notify.WebPush.SubscriptionsTest do
  @moduledoc """
  Subscribing a browser, listing what someone is reachable on, and removing one by endpoint.

  Two rows per subscription, which is what makes a shared browser safe: the device is keyed on its endpoint and the subscription is per person, so two accounts can subscribe the same browser and each keeps their own. Re-subscribing an endpoint updates its keys rather than making a second device.
  """
  use Bonfire.Notify.DataCase, async: true
  use Bonfire.Common.Repo

  alias Bonfire.Data.Identity.User
  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.WebPush

  defp subscribe(user, data), do: WebPush.subscribe(Bonfire.Common.Types.uid(user), data)

  # what this person is reachable on, which is the list the settings UI shows
  defp addresses(user) do
    WebPush.list_subscriptions(Bonfire.Common.Types.uid(user))
    |> Enum.map(& &1.push_device.address)
    |> Enum.sort()
  end

  describe "create/2" do
    setup do
      user = fake_user!()
      {:ok, %{user: user}}
    end

    test "inserts the subscription for the user", %{user: %User{id: user_id} = user} do
      {:ok, user_sub1} = subscribe(user, valid_push_subscription_data("a"))
      assert user_sub1.id == user_id
      assert user_sub1.push_device_id

      # subscribing the same endpoint again returns the same subscription
      {:ok, user_sub2} = subscribe(user, valid_push_subscription_data("a"))
      assert user_sub2.push_device_id == user_sub1.push_device_id
      assert addresses(user) == ["a"]

      # and a different endpoint is a second device
      {:ok, _} = subscribe(user, valid_push_subscription_data("b"))
      assert addresses(user) == ["a", "b"]

      # two people can be reachable on one browser, each through their own subscription
      another_user = fake_user!()
      {:ok, theirs} = subscribe(another_user, valid_push_subscription_data("a"))

      assert theirs.push_device_id == user_sub1.push_device_id
      assert addresses(another_user) == ["a"]
      assert addresses(user) == ["a", "b"]
    end

    test "returns an error if the JSON payload is invalid", %{user: user} do
      assert {:error, :invalid_json} = subscribe(user, "{invalid")
      assert addresses(user) == []
    end

    test "returns a changeset error if the payload has the wrong structure", %{user: user} do
      assert {:error, %Ecto.Changeset{}} = subscribe(user, %{"foo" => "bar"})
      assert addresses(user) == []
    end

    test "updates the device's keys when an endpoint re-subscribes", %{user: user} do
      {:ok, user_sub1} = subscribe(user, valid_push_subscription_data("endpoint1"))
      original_device_id = user_sub1.push_device_id

      data =
        valid_push_subscription_map("endpoint1")
        |> put_in(["keys", "auth"], "new_auth_key")

      {:ok, user_sub2} = subscribe(user, data)

      # the same browser, so the same device row, with the keys it just sent
      assert user_sub2.push_device_id == original_device_id
      assert repo().get!(PushDevice, original_device_id).auth_key == "new_auth_key"
    end

    test "a browser is a web device, so native delivery never sees it", %{user: user} do
      {:ok, user_sub} = subscribe(user, valid_push_subscription_data("browser"))

      assert repo().get!(PushDevice, user_sub.push_device_id).provider == :web
      assert Bonfire.Notify.NativePush.targets([user.id]) == []
    end
  end

  describe "list_subscriptions/1" do
    test "returns nothing for someone with no subscriptions" do
      assert addresses(fake_user!()) == []
    end

    test "leaves out a device that stopped working" do
      user = fake_user!()
      {:ok, user_sub} = subscribe(user, valid_push_subscription_data("active"))

      repo().get!(PushDevice, user_sub.push_device_id)
      |> PushDevice.mark_status({:expired, :gone})

      assert addresses(user) == []
    end

    test "returns each person their own subscriptions" do
      user1 = fake_user!()
      user2 = fake_user!()

      {:ok, _} = subscribe(user1, valid_push_subscription_data("user1_sub1"))
      {:ok, _} = subscribe(user1, valid_push_subscription_data("user1_sub2"))
      {:ok, _} = subscribe(user2, valid_push_subscription_data("user2_sub1"))

      assert addresses(user1) == ["user1_sub1", "user1_sub2"]
      assert addresses(user2) == ["user2_sub1"]
    end
  end

  describe "remove_subscription_by_endpoint/1" do
    test "removes the device, and with it everyone's subscriptions to it" do
      user = fake_user!()
      other = fake_user!()
      {:ok, _} = subscribe(user, valid_push_subscription_data("to_remove"))
      {:ok, _} = subscribe(other, valid_push_subscription_data("to_remove"))

      assert addresses(user) == ["to_remove"]

      WebPush.remove_subscription_by_endpoint("to_remove")

      assert addresses(user) == []
      assert addresses(other) == []
    end
  end
end
