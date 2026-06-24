defmodule Bonfire.Notify.NativePushTest do
  use Bonfire.Notify.DataCase, async: false

  alias Bonfire.Notify.NativePush
  alias Bonfire.Notify.NativePushDevice
  import Bonfire.Common.Config, only: [repo: 0]

  describe "native push devices" do
    test "registers and updates a native device token for a user" do
      user = fake_user!()

      attrs = %{
        provider: "FCM",
        token: "native-token-1",
        platform: "ios",
        device_name: "Ivan's iPhone",
        alerts: %{mention: true, poll: false},
        policy: "all"
      }

      assert {:ok, device} = NativePush.register(user, attrs)
      assert device.id
      assert device.user_id == user.id
      assert device.provider == "fcm"
      assert device.token == "native-token-1"
      assert device.token_hash == NativePushDevice.hash_token("native-token-1")
      assert device.alerts["mention"] == true
      assert device.alerts["poll"] == false

      assert {:ok, updated} =
               NativePush.register(user, %{attrs | device_name: "Ivan's new iPhone"})

      assert updated.id == device.id
      assert updated.device_name == "Ivan's new iPhone"
      assert [listed] = NativePush.list_devices(user)
      assert listed.id == device.id
    end

    test "removes only devices owned by the user" do
      user = fake_user!()
      other = fake_user!()

      assert {:ok, device} =
               NativePush.register(user, %{
                 provider: "apns",
                 token: "apns-token",
                 platform: "ios"
               })

      assert {:error, :not_found} = NativePush.remove_device(other, device.id)
      assert [_] = NativePush.list_devices(user)

      assert {:ok, _deleted} = NativePush.remove_device(user, device.id)
      assert [] = NativePush.list_devices(user)
    end

    test "does not accept user_id from device attrs" do
      user = fake_user!()
      attacker = fake_user!()

      assert {:ok, device} =
               NativePush.register(user, %{
                 provider: "fcm",
                 token: "owned-token",
                 user_id: attacker.id
               })

      assert device.user_id == user.id
    end

    test "filters native sends by alerts and policy" do
      configure_native_push_adapter()

      sender = fake_user!()
      allowed = fake_user!()
      alerts_off = fake_user!()
      policy_none = fake_user!()

      assert {:ok, allowed_device} =
               NativePush.register(allowed, %{
                 provider: "fcm",
                 token: "allowed-token",
                 alerts: %{mention: true},
                 policy: "all"
               })

      assert {:ok, _alerts_off_device} =
               NativePush.register(alerts_off, %{
                 provider: "fcm",
                 token: "alerts-off-token",
                 alerts: %{mention: false},
                 policy: "all"
               })

      assert {:ok, _policy_none_device} =
               NativePush.register(policy_none, %{
                 provider: "fcm",
                 token: "policy-none-token",
                 alerts: %{mention: true},
                 policy: "none"
               })

      assert [{:ok, sent_device, :sent}] =
               NativePush.send_native_push(
                 [allowed.id, alerts_off.id, policy_none.id],
                 "msg",
                 notify_category: :messages,
                 from_id: sender.id
               )

      assert sent_device.id == allowed_device.id

      assert_receive {:native_push_send, [^allowed_device], "msg", []}
    end

    test "tracks successful native delivery status" do
      configure_native_push_adapter()

      user = fake_user!()

      assert {:ok, device} =
               NativePush.register(user, %{
                 provider: "fcm",
                 token: "status-success-token"
               })

      assert [{:ok, ^device, :sent}] = NativePush.send_native_push(user.id, "msg")

      updated = repo().get!(NativePushDevice, device.id)
      assert updated.active == true
      assert updated.last_status == :success
      assert updated.last_used_at
      assert updated.last_error == nil
    end

    test "marks expired native tokens inactive" do
      configure_native_push_adapter(:expired)

      user = fake_user!()

      assert {:ok, device} =
               NativePush.register(user, %{
                 provider: "apns",
                 token: "expired-token"
               })

      assert [{:error, ^device, :expired}] = NativePush.send_native_push(user.id, "msg")

      updated = repo().get!(NativePushDevice, device.id)
      assert updated.active == false
      assert updated.last_status == :expired
      assert updated.last_used_at
      assert updated.last_error == ":expired"
    end
  end

  defp configure_native_push_adapter(result \\ :ok) do
    previous_adapter = Application.get_env(:bonfire_notify, :native_push_adapter)
    previous_pid = Application.get_env(:bonfire_notify, :native_push_test_pid)
    previous_result = Application.get_env(:bonfire_notify, :native_push_test_result)

    Application.put_env(
      :bonfire_notify,
      :native_push_adapter,
      Bonfire.Notify.Test.NativePushAdapter
    )

    Application.put_env(:bonfire_notify, :native_push_test_pid, self())
    Application.put_env(:bonfire_notify, :native_push_test_result, result)

    on_exit(fn ->
      restore_env(:native_push_adapter, previous_adapter)
      restore_env(:native_push_test_pid, previous_pid)
      restore_env(:native_push_test_result, previous_result)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:bonfire_notify, key)
  defp restore_env(key, value), do: Application.put_env(:bonfire_notify, key, value)
end
