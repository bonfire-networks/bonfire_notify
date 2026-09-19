defmodule Bonfire.Notify.PushReconcileTest do
  @moduledoc """
  Making what the browser holds and what we have stored agree, on mount.

  They are the same fact in two places and they drift: a registration whose event never reached the server, a row pruned by a failed send while the browser kept its subscription, cleared site data. The symptom is a toggle that reads "on" while nothing arrives, or "off" while `subscribe()` hands back the very endpoint we deleted.

  The browser reports what it has and the server decides, since only the server knows whether a row exists for this person and endpoint. Reporting, not asking: permission is never requested here, because a browser resolves that to `denied` without prompting once blocked.
  """
  use Bonfire.Notify.ConnCase, async: false

  alias Bonfire.Notify.WebPush

  @endpoint_url "https://push.bonfire.local/reconciled"

  setup do
    configure_web_push()
    user = fake_user!()

    {:ok, user: user}
  end

  # what the hook sends on mount: the whole subscription as the browser has it, or nothing, plus the permission only the client can know
  defp report(view, subscription, permission \\ "granted") do
    view
    |> element("[phx-hook=PushSettingsHook]")
    |> render_hook("check_subscription", %{
      "subscription" => subscription,
      "permission" => permission
    })
  end

  defp panel(user) do
    {:ok, view, _html} = live(conn(user: user, account: user.account), "/notifications")
    view
  end

  test "a subscription the browser has and we don't is stored as it stands", %{user: user} do
    assert WebPush.list_subscriptions(user.id) == []

    html = panel(user) |> report(valid_push_subscription_map(@endpoint_url))

    assert [subscription] = WebPush.list_subscriptions(user.id),
           "an earlier registration that never reached us leaves the browser subscribed and us silent"

    assert subscription.push_device.address == @endpoint_url
    assert subscription.push_device.provider == :web
    assert html =~ "Enabled on this device"
  end

  test "reporting the same subscription again changes nothing", %{user: user} do
    view = panel(user)
    report(view, valid_push_subscription_map(@endpoint_url))
    assert [first] = WebPush.list_subscriptions(user.id)

    # writing here re-renders the panel, which re-mounts the hook, so this has to be idempotent or a render becomes a write cycle
    report(view, valid_push_subscription_map(@endpoint_url))

    assert [again] = WebPush.list_subscriptions(user.id)
    assert again.push_device_id == first.push_device_id
  end

  test "a browser with no subscription says so without touching anyone's devices", %{user: user} do
    {:ok, _} = WebPush.subscribe(user.id, valid_push_subscription_map(@endpoint_url))

    html = panel(user) |> report(nil)

    refute html =~ "Enabled on this device"

    assert [_still_there] = WebPush.list_subscriptions(user.id),
           "nothing here says which device this browser was, and removing the wrong one would unsubscribe another. A dead row is deactivated by its next failed send"
  end

  describe "turning push off on a browser two people share" do
    defp disable(view, endpoint) do
      view
      |> element("[phx-hook=PushSettingsHook]")
      |> render_hook("push_subscription_disabled", %{"endpoint" => endpoint})
    end

    test "unsubscribes the one who asked and leaves the other subscribed", %{user: alice} do
      bob = fake_user!()

      {:ok, _} = WebPush.subscribe(alice.id, valid_push_subscription_map(@endpoint_url))
      {:ok, bobs} = WebPush.subscribe(bob.id, valid_push_subscription_map(@endpoint_url))

      disable(panel(alice), @endpoint_url)

      assert WebPush.list_subscriptions(alice.id) == []

      assert [still_bobs] = WebPush.list_subscriptions(bob.id),
             "deleting the device because one account turned push off would silently unsubscribe the others"

      assert still_bobs.push_device_id == bobs.push_device_id
    end

    test "the device itself goes when the last person unsubscribes", %{user: alice} do
      {:ok, subscription} =
        WebPush.subscribe(alice.id, valid_push_subscription_map(@endpoint_url))

      disable(panel(alice), @endpoint_url)

      assert WebPush.list_subscriptions(alice.id) == []

      refute Bonfire.Notify.WebPushDevice.get_by_endpoint(@endpoint_url),
             "with nobody subscribed there is nothing left to deliver to, and the browser is told to drop its subscription too"

      refute Bonfire.Common.Config.repo().get(
               Bonfire.Notify.PushDevice,
               subscription.push_device_id
             )
    end
  end

  test "a blocked browser is told where to unblock rather than offered a toggle", %{user: user} do
    html = panel(user) |> report(nil, "denied")

    assert html =~ "Blocked in your browser settings"

    assert html |> Floki.parse_document!() |> Floki.find("[phx-click=enable_push]") == [],
           "a blocked origin cannot be re-prompted, so offering to enable it would offer something that cannot work"
  end
end
