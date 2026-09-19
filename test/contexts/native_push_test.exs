defmodule Bonfire.Notify.NativePushTest do
  use Bonfire.Notify.DataCase, async: false

  alias Bonfire.Notify.NativePush

  describe "native push devices" do
    test "registers and updates a native device token for a user" do
      user = fake_user!()

      attrs = %{
        provider: "FCM",
        token: "native-token-1",
        platform: "ios",
        device_name: "Ivan's iPhone",
        policy: "all"
      }

      assert {:ok, subscription} = NativePush.register(user, attrs)
      assert subscription.id == user.id
      assert subscription.policy == "all"

      device = subscription.push_device
      assert device.id
      assert device.provider == :fcm
      assert device.address == "native-token-1"
      assert device.device_agent == "ios"

      assert {:ok, updated} =
               NativePush.register(user, %{attrs | device_name: "Ivan's new iPhone"})

      assert updated.push_device_id == device.id
      assert updated.push_device.device_name == "Ivan's new iPhone"
      assert [listed] = NativePush.list_devices(user)
      assert listed.push_device_id == device.id
    end

    test "a second account on one device gets its own subscription rather than taking it over" do
      alice = fake_user!()
      bob = fake_user!()

      attrs = %{provider: "apns", token: "one-phone", platform: "ios"}

      assert {:ok, for_alice} = NativePush.register(alice, attrs)
      assert {:ok, for_bob} = NativePush.register(bob, attrs)

      # one device, a subscription each: registering says where to reach someone, so it can never stop reaching someone else
      assert for_bob.push_device_id == for_alice.push_device_id
      assert [alices] = NativePush.list_devices(alice)
      assert [bobs] = NativePush.list_devices(bob)
      assert alices.id == alice.id
      assert bobs.id == bob.id
    end

    test "removes only the subscriptions belonging to the user" do
      user = fake_user!()
      other = fake_user!()

      assert {:ok, subscription} =
               NativePush.register(user, %{
                 provider: "apns",
                 token: "apns-token",
                 platform: "ios"
               })

      device_id = subscription.push_device_id

      assert {:error, :not_found} = NativePush.remove_device(other, device_id)
      assert [_] = NativePush.list_devices(user)

      assert {:ok, _deleted} = NativePush.remove_device(user, device_id)
      assert [] = NativePush.list_devices(user)
    end

    test "unsubscribing leaves the device for whoever else uses it" do
      alice = fake_user!()
      bob = fake_user!()
      attrs = %{provider: "fcm", token: "shared-phone"}

      assert {:ok, for_alice} = NativePush.register(alice, attrs)
      assert {:ok, _for_bob} = NativePush.register(bob, attrs)

      assert {:ok, _} = NativePush.remove_device(alice, for_alice.push_device_id)

      assert [] = NativePush.list_devices(alice)
      assert [still_there] = NativePush.list_devices(bob)
      assert still_there.push_device_id == for_alice.push_device_id
    end

    test "does not accept a user id from the device attrs" do
      user = fake_user!()
      attacker = fake_user!()

      assert {:ok, subscription} =
               NativePush.register(user, %{
                 provider: "fcm",
                 token: "owned-token",
                 user_id: attacker.id
               })

      assert subscription.id == user.id
      assert [] = NativePush.list_devices(attacker)
    end

    test "refuses a gateway we cannot send through" do
      user = fake_user!()

      assert {:error, changeset} =
               NativePush.register(user, %{provider: "carrier-pigeon", token: "some-token"})

      assert Keyword.has_key?(changeset.errors, :provider)
      assert [] = NativePush.list_devices(user)
    end

    # Which devices a notification goes to, and what each provider answer means, moved with the batch
    # send path they used to test: `test/channels/native_push_channel_test.exs` covers both against the
    # channel a delivery job actually uses, per device rather than per batch.
  end
end
