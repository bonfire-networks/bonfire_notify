defmodule Bonfire.Notify.NativePushChannelTest do
  @moduledoc """
  Native push as a delivery channel: which devices someone has, and what the provider's answer means for the job that sent it.

  A token the provider says is gone will never work again, so the device is deactivated and the job cancelled rather than retried. Anything else is worth another attempt. An instance with no native adapter cancels too, since no number of retries configures one.

  A target is re-read as this person's subscription to the device, so a phone somebody else also registered cannot receive the first account's notification.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E

  alias Bonfire.Notify.NativePush
  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription
  import Bonfire.Common.Config, only: [repo: 0]

  setup do
    user = fake_user!()
    other = fake_user!()

    {:ok, link} = register(user, "token-one")

    {:ok, user: user, other: other, link: link}
  end

  defp register(user, token) do
    NativePush.register(user, %{provider: "apns", token: token, platform: "ios"})
  end

  defp content, do: %{title: "Alice", body: "said something", url: "/post/1", tag: "abc"}

  defp device(link), do: repo().get!(PushDevice, link.push_device_id)

  defp deliver(user, link, result) do
    configure_native_push(result)
    assert {:ok, target} = NativePush.target(link.push_device_id, user.id)
    NativePush.deliver(target, content())
  end

  test "every active device someone has is a target", %{user: user, link: link} do
    {:ok, second} = register(user, "token-two")

    targets = NativePush.targets([user.id])

    assert length(targets) == 2

    assert Enum.sort(Enum.map(targets, & &1.target_id)) ==
             Enum.sort([link.push_device_id, second.push_device_id])

    assert Enum.all?(targets, &(&1.user_id == user.id))
  end

  test "somebody with no device has no targets", %{other: other} do
    assert NativePush.targets([other.id]) == []
  end

  describe "what a subscription can decide" do
    test "one registered our own way carries no alerts, so settings alone decide", %{
      user: user,
      link: link
    } do
      refute link.alerts,
             "registering says where to reach someone, so nothing about what to send is stored here"

      assert [_] = NativePush.targets([user.id], :like)
      assert [_] = NativePush.targets([user.id], :mention)
    end

    test "one carrying a Mastodon alerts map takes only the types it asked for", %{
      user: user,
      link: link
    } do
      # only that API's own path stores such a map, and it documents every alert as defaulting to false
      assert {:ok, _} =
               UserPushSubscription.upsert(user.id, link.push_device_id, %{
                 alerts: %{"mention" => true}
               })

      assert [_] = NativePush.targets([user.id], :mention)

      assert NativePush.targets([user.id], :like) == [],
             "a type left out is a type it does not want, not one for us to decide"
    end

    test "a device set not to be pushed to takes nothing at all", %{user: user, link: link} do
      assert {:ok, _} =
               UserPushSubscription.upsert(user.id, link.push_device_id, %{policy: "none"})

      assert NativePush.targets([user.id], :like) == []
      assert NativePush.targets([user.id], :mention) == []
    end
  end

  test "a subscription belongs to one person, so another cannot be delivered to through it", %{
    user: user,
    other: other,
    link: link
  } do
    assert {:ok, _} = NativePush.target(link.push_device_id, user.id)

    assert {:error, :inactive} = NativePush.target(link.push_device_id, other.id),
           "somebody else registering the same phone must not receive this account's notification"
  end

  test "an inactive device is not a target any more", %{user: user, link: link} do
    PushDevice.mark_status(device(link), {:expired, :gone})

    assert {:error, :inactive} = NativePush.target(link.push_device_id, user.id)
    assert NativePush.targets([user.id]) == []
  end

  test "a delivered notification is recorded as delivered", %{user: user, link: link} do
    assert :ok = deliver(user, link, :ok)

    assert_receive {:native_push_send, [_device], payload, _opts}
    assert Jason.decode!(payload)["title"] == "Alice"

    recorded = device(link)
    assert recorded.last_status == :success
    assert recorded.active == true
    assert recorded.last_error == nil
  end

  test "a token the provider says is gone is deactivated and cancelled", %{
    user: user,
    link: link
  } do
    assert {:cancel, :inactive} = deliver(user, link, :expired)

    recorded = device(link)
    assert recorded.active == false
    assert recorded.last_status == :expired
  end

  test "any other failure is worth retrying", %{user: user, link: link} do
    assert {:error, :timeout} = deliver(user, link, {:error, :timeout})

    recorded = device(link)
    assert recorded.active == true, "a device that timed out is still a device"
    assert recorded.last_status == :error
  end

  test "with no adapter configured there is nothing to retry", %{user: user, link: link} do
    # the target is read while an adapter is configured, then it goes away, since that is the order a job would meet it
    configure_native_push()
    assert {:ok, target} = NativePush.target(link.push_device_id, user.id)

    Application.delete_env(:bonfire_notify, :native_push_adapter)

    assert {:cancel, :native_push_not_configured} = NativePush.deliver(target, content())
  end

  test "a delivery shapes its own payload, and refuses finished bytes", %{user: user, link: link} do
    configure_native_push()
    assert {:ok, target} = NativePush.target(link.push_device_id, user.id)

    assert :ok = NativePush.deliver(target, content())
    assert_receive {:native_push_send, [_device], payload, _opts}
    assert Jason.decode!(payload)["title"] == "Alice"

    # bytes cannot be reshaped for a target, so a caller that hands them over is refused loudly rather than having its payload sent as a string of nulls
    assert {:cancel, _} = NativePush.deliver(target, Jason.encode!(content()))
    refute_receive {:native_push_send, _, _, _}
  end

  test "a browser someone has subscribed is not a native target", %{user: user} do
    assert {:ok, _} =
             Bonfire.Notify.WebPush.subscribe(
               user.id,
               valid_push_subscription_map("https://push.bonfire.local/browser")
             )

    assert Enum.map(NativePush.targets([user.id]), & &1.target_id) |> length() == 1,
           "one device table means each channel has to ask for its own transport"
  end
end
