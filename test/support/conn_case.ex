defmodule Bonfire.Notifications.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MyApp.Web.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  @repo Application.get_env(:bonfire_notifications, :repo_module)

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Bonfire.Notifications.ConnCase
      import Bonfire.Notifications.Test.ConnHelpers
      import Bonfire.Notifications.Test.FakeHelpers
      alias Bonfire.Notifications.Fake
      alias Bonfire.Notifications.Web.Router.Helpers, as: Routes

      # The default endpoint for testing
      @endpoint Bonfire.Notifications.Web.Endpoint
    end
  end

  setup tags do

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    end

    {:ok, []}
  end

end
