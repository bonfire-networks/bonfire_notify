defmodule Bonfire.Notify.PushEnableFeedbackTest do
  @moduledoc """
  What the panel says when enabling push does not work.

  Permission is asked for before the subscribe, so a browser that refuses the *subscribe* leaves permission granted, and notifications still arrive whenever a page is open. Calling that "failed" tells somebody nothing worked when something does, so the message turns on the permission the browser reports, not on the failure alone.

  The wording is asserted on `enable_failure_message/3`, the function that composes it, because the flash it is handed renders in `Bonfire.UI.Common.NotificationLive` from the parent LiveView's flash and is not in the HTML a component-targeted `render_hook` returns. The event itself is covered below, that it is handled and leaves the panel standing.
  """
  use Bonfire.Notify.ConnCase, async: false

  alias Bonfire.Notify.Settings.PushNotificationsLive

  setup do
    configure_web_push()
    {:ok, user: fake_user!()}
  end

  describe "enable_failure_message/3" do
    test "with permission granted, says notifications still arrive while a page is open" do
      message =
        PushNotificationsLive.enable_failure_message(
          "AbortError",
          "Error retrieving push subscription",
          "granted"
        )

      assert message =~ "could not reach a push service",
             "the browser's own AbortError names nothing anyone can act on, so the panel says what to try"

      assert message =~ "while Bonfire is open in a tab",
             "permission survived the failed subscribe, so notifications on this device are not gone, only limited to when a page is open"
    end

    test "with permission refused, says what that costs and promises nothing more" do
      message =
        PushNotificationsLive.enable_failure_message(
          "NotAllowedError",
          "Permission denied",
          "denied"
        )

      assert message =~ "site settings"

      assert message =~ "only see them inside the Bonfire page",
             "no OS notification is possible by either path, so the in-app surfaces are the whole answer"

      refute message =~ "while Bonfire is open in a tab",
             "that promise belongs to a granted permission, and would be a lie here"
    end

    test "with permission never asked, says what it costs until it is allowed" do
      message = PushNotificationsLive.enable_failure_message("AbortError", "nope", "default")

      assert message =~ "only see them inside the Bonfire page"
      refute message =~ "while Bonfire is open in a tab"
    end

    test "with no permission reported, claims nothing about what works" do
      message = PushNotificationsLive.enable_failure_message(nil, "boom", nil)

      assert message =~ "boom"
      refute message =~ "while Bonfire is open in a tab"
      refute message =~ "only see them inside the Bonfire page"
    end
  end

  test "the panel handles a failed subscribe and keeps its own state", %{user: user} do
    {:ok, view, _html} = live(conn(user: user, account: user.account), "/notifications")

    html =
      view
      |> element("[phx-hook=PushSettingsHook]")
      |> render_hook("push_subscription_error", %{
        "error" => "Error retrieving push subscription",
        "name" => "AbortError",
        "permission" => "granted"
      })

    assert html =~ "Notifications",
           "a failed subscribe is reported, not fatal: the panel is still there to try again"

    refute html =~ "Enabled on this device",
           "nothing was subscribed, so the toggle must not claim otherwise"
  end
end
