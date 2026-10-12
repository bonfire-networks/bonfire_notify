defmodule Bonfire.Notify.PushStepTest do
  @moduledoc "The push component's `:step` form, as shown in the getting-started widget."
  use Bonfire.Notify.ConnCase, async: false

  alias Bonfire.Notify.Settings.PushNotificationsLive

  test "step_state/1 says where this browser stands" do
    reported = %{
      reported: true,
      push_supported: true,
      vapid_public_key: "key",
      permission: "default"
    }

    for {assigns, state} <- [
          {%{reported | reported: false}, :checking},
          {reported, :offer},
          {Map.put(reported, :current_device_subscribed, true), :on},
          {%{reported | permission: "denied"}, :blocked},
          {%{reported | push_supported: false}, :unsupported},
          {%{reported | vapid_public_key: nil}, :unconfigured}
        ] do
      assert PushNotificationsLive.step_state(assigns) == state
    end
  end

  describe "on a page" do
    setup do
      configure_web_push()
      user = fake_user!()
      {:ok, view, _html} = live(conn(user: user, account: user.account), "/dashboard")
      {:ok, view: view}
    end

    @hook "#push-settings-widget_getting_started_notifications"

    # the widget shows one step at a time
    defp step_hook(view, tries \\ 10) do
      cond do
        has_element?(view, @hook) ->
          element(view, @hook)

        tries > 0 and has_element?(view, "[data-id=widget_getting_started_next]") ->
          view |> element("[data-id=widget_getting_started_next]") |> render_click()
          step_hook(view, tries - 1)

        true ->
          flunk("the getting-started widget never showed the notifications step")
      end
    end

    test "says it can't, rather than waiting for good, when the browser has no push", %{
      view: view
    } do
      view |> step_hook() |> render_hook("push_not_supported", %{})

      assert has_element?(view, "[data-id=push_step_unsupported]")
      refute has_element?(view, "[data-id=push_step_enable]")
    end

    test "switches to the blocked guidance as soon as the prompt is refused", %{view: view} do
      view
      |> step_hook()
      |> render_hook("check_subscription", %{"subscription" => nil, "permission" => "default"})

      assert has_element?(view, "[data-id=push_step_enable]")

      view
      |> step_hook()
      |> render_hook("push_subscription_error", %{
        "error" => "Permission denied",
        "name" => "NotAllowedError",
        "permission" => "denied"
      })

      assert has_element?(view, "[data-id=push_step_blocked]")
      refute has_element?(view, "[data-id=push_step_enable]")
    end
  end
end
