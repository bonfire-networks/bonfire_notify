defmodule Bonfire.Notify.AppBannerTest do
  @moduledoc "The bottom card offering install and push, as the layout mounts it on every page."
  use Bonfire.Notify.ConnCase, async: false

  @banner "#app-banner"
  @push_row "#push-settings-app-banner-push"

  defp dashboard do
    user = fake_user!()
    {:ok, view, _html} = live(conn(user: user, account: user.account), "/dashboard")
    view
  end

  describe "with push configured" do
    setup do
      configure_web_push()
      {:ok, view: dashboard()}
    end

    test "is an empty shell until its hook sends the rows", %{view: view} do
      assert has_element?(view, @banner)
      refute has_element?(view, @push_row)
      refute has_element?(view, "[data-app-banner-dismiss]")
    end

    test "shows the push offer once its hook says it applies", %{view: view} do
      view |> element(@banner) |> render_hook("rows", %{"push" => true})

      assert has_element?(view, @push_row)
      assert has_element?(view, "#{@banner} button[phx-click=enable_push]")
    end

    test "drops the card again when no row applies", %{view: view} do
      view |> element(@banner) |> render_hook("rows", %{"push" => true, "install" => true})
      view |> element(@banner) |> render_hook("rows", %{})

      refute has_element?(view, @push_row)
      refute has_element?(view, "[data-app-banner-dismiss]")
    end
  end

  test "never shows the push row without VAPID keys" do
    previous = Application.get_all_env(:ex_nudge)
    Application.put_env(:ex_nudge, :vapid_public_key, nil)
    Application.put_env(:ex_nudge, :vapid_private_key, nil)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:ex_nudge, key, value) end)
    end)

    view = dashboard()
    view |> element(@banner) |> render_hook("rows", %{"push" => true})

    refute has_element?(view, @push_row)
  end
end
