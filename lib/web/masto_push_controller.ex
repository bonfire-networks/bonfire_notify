defmodule Bonfire.Notify.Web.MastoPushController do
  @moduledoc """
  Mastodon-compatible Push Subscription REST endpoints.

  Implements:
  - POST /api/v1/push/subscription - Create subscription
  - GET /api/v1/push/subscription - Get current subscription
  - PUT /api/v1/push/subscription - Update subscription
  - DELETE /api/v1/push/subscription - Delete subscription
  """

  use Bonfire.UI.Common.Web, :controller
  import Untangle

  alias Bonfire.Notify.API.MastoPushAdapter

  def create(conn, params) do
    debug(params, "POST /api/v1/push/subscription")
    MastoPushAdapter.create(params, conn)
  end

  def show(conn, _params) do
    debug("GET /api/v1/push/subscription")
    MastoPushAdapter.show(conn)
  end

  def update(conn, params) do
    debug(params, "PUT /api/v1/push/subscription")
    MastoPushAdapter.update(params, conn)
  end

  def delete(conn, _params) do
    debug("DELETE /api/v1/push/subscription")
    MastoPushAdapter.delete(conn)
  end
end
