defmodule Bonfire.Notify.Web.Routes do
  @behaviour Bonfire.UI.Common.RoutesModule

  defmacro __using__(_) do
    quote do
      # pages anyone can view
      scope "/", Bonfire.Notify.Web do
        pipe_through(:browser)
      end

      # pages only guests can view
      scope "/", Bonfire.Notify.Web do
        pipe_through([:throttle_forms, :browser, :guest_only])
      end

      # pages you need an account to view
      scope "/", Bonfire.Notify.Web do
        pipe_through(:browser)
        pipe_through(:account_required)
      end

      # pages you need to view as a user
      scope "/", Bonfire.Notify.Web do
        pipe_through(:browser)
        pipe_through(:user_required)

        get "/api/v1-bonfire/streaming", Bonfire.Notify.Web.StreamingController, :stream
      end

      # pages only admins can view
      scope "/", Bonfire.Notify.Web do
        pipe_through(:browser)
        pipe_through(:admin_required)
      end
    end
  end
end
