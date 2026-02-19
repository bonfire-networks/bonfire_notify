# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Notify.Web.MastoPushApiTest do
  @moduledoc """
  Tests for Mastodon-compatible push subscription endpoints:
  - POST /api/v1/push/subscription
  - GET /api/v1/push/subscription
  - PUT /api/v1/push/subscription
  - DELETE /api/v1/push/subscription

  Run with: just test extensions/bonfire_notify/test/api/masto_push_api_test.exs
  """

  use Bonfire.Notify.ConnCase, async: false

  alias Bonfire.Me.Fake
  alias Bonfire.OpenID.Provider.ClientApps
  alias Boruta.Ecto.AccessTokens, as: AccessTokensAdapter
  import Boruta.Ecto.OauthMapper, only: [to_oauth_schema: 1]

  @moduletag :masto_api

  setup do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = build_authenticated_conn(user)

    {:ok, conn: conn, user: user}
  end

  defp build_authenticated_conn(user) do
    {:ok, ecto_client} =
      ClientApps.new(%{
        id: Faker.UUID.v4(),
        name: "test-push-app",
        redirect_uris: ["http://localhost:4000/oauth/callback"]
      })

    {:ok, token} =
      AccessTokensAdapter.create(
        %{client: to_oauth_schema(ecto_client), sub: user.id, scope: "read write push"},
        []
      )

    Phoenix.ConnTest.build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token.value}")
  end

  defp unauthenticated_conn do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp create_subscription(conn, opts \\ []) do
    conn
    |> post("/api/v1/push/subscription", subscription_params(opts))
    |> json_response(200)
  end

  defp subscription_params(opts \\ []) do
    %{
      "subscription" => %{
        "endpoint" => opts[:endpoint] || "https://push.example.com/#{Faker.UUID.v4()}",
        "keys" => %{
          "p256dh" =>
            opts[:p256dh] || Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
          "auth" =>
            opts[:auth] || Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      },
      "data" => %{
        "alerts" =>
          opts[:alerts] ||
            %{
              "mention" => true,
              "reblog" => true,
              "favourite" => true,
              "follow" => true,
              "poll" => false
            },
        "policy" => opts[:policy] || "all"
      }
    }
  end

  describe "POST /api/v1/push/subscription" do
    test "creates a push subscription", %{conn: conn} do
      params = subscription_params()

      response =
        conn
        |> post("/api/v1/push/subscription", params)
        |> json_response(200)

      assert Map.has_key?(response, "id")
      assert response["endpoint"] == params["subscription"]["endpoint"]
      assert Map.has_key?(response, "server_key")
      assert response["alerts"]["mention"] == true
      assert response["policy"] == "all"
    end

    test "creates subscription with custom alerts and policy", %{conn: conn} do
      params =
        subscription_params(
          alerts: %{"mention" => false, "reblog" => true, "follow" => false},
          policy: "follower"
        )

      response =
        conn
        |> post("/api/v1/push/subscription", params)
        |> json_response(200)

      assert response["alerts"]["mention"] == false
      assert response["alerts"]["reblog"] == true
      assert response["alerts"]["follow"] == false
      assert response["policy"] == "follower"
    end

    test "updates existing subscription if endpoint exists", %{conn: conn} do
      endpoint = "https://push.example.com/#{Faker.UUID.v4()}"
      params = subscription_params(endpoint: endpoint, alerts: %{"mention" => true})

      first_response =
        conn
        |> post("/api/v1/push/subscription", params)
        |> json_response(200)

      # Create again with same endpoint but different alerts
      params2 = subscription_params(endpoint: endpoint, alerts: %{"mention" => false})

      second_response =
        conn
        |> post("/api/v1/push/subscription", params2)
        |> json_response(200)

      # Should update, not create new
      assert first_response["id"] == second_response["id"]
      assert second_response["alerts"]["mention"] == false
    end

    test "returns 401 without authorization", %{} do
      response =
        unauthenticated_conn()
        |> post("/api/v1/push/subscription", subscription_params())
        |> json_response(401)

      assert response["error"] =~ "You need to login first." or response["error"] =~ "invalid"
    end

    test "returns error for invalid subscription data", %{conn: conn} do
      response =
        conn
        |> post("/api/v1/push/subscription", %{"invalid" => "data"})
        |> json_response(400)

      assert Map.has_key?(response, "error")
    end
  end

  describe "GET /api/v1/push/subscription" do
    test "cannot access another user's subscription", %{conn: conn} do
      # Create subscription for another user
      other_account = Fake.fake_account!()
      other_user = Fake.fake_user!(other_account)
      other_conn = build_authenticated_conn(other_user)
      create_subscription(other_conn)

      # My GET shouldn't see other user's subscription
      response =
        conn
        |> get("/api/v1/push/subscription")
        |> json_response(404)

      assert response["error"] =~ "Not found"
    end

    test "returns the current subscription", %{conn: conn} do
      created = create_subscription(conn)

      response =
        conn
        |> get("/api/v1/push/subscription")
        |> json_response(200)

      assert response["endpoint"] == created["endpoint"]
      assert Map.has_key?(response, "server_key")
      assert Map.has_key?(response, "alerts")
      assert Map.has_key?(response, "policy")
    end

    test "returns 404 when no subscription exists", %{conn: conn} do
      response =
        conn
        |> get("/api/v1/push/subscription")
        |> json_response(404)

      assert response["error"] =~ "Not found"
    end

    test "returns 401 without authorization", %{} do
      response =
        unauthenticated_conn()
        |> get("/api/v1/push/subscription")
        |> json_response(401)

      assert response["error"] =~ "You need to login first." or response["error"] =~ "invalid"
    end
  end

  describe "PUT /api/v1/push/subscription" do
    test "updates subscription alerts", %{conn: conn} do
      create_subscription(conn, alerts: %{"mention" => true, "reblog" => true})

      response =
        conn
        |> put("/api/v1/push/subscription", %{"data" => %{"alerts" => %{"mention" => false}}})
        |> json_response(200)

      assert response["alerts"]["mention"] == false
      assert response["alerts"]["reblog"] == true
    end

    test "updates subscription policy", %{conn: conn} do
      create_subscription(conn, policy: "all")

      response =
        conn
        |> put("/api/v1/push/subscription", %{"data" => %{"policy" => "follower"}})
        |> json_response(200)

      assert response["policy"] == "follower"
    end

    test "returns 404 when no subscription exists", %{conn: conn} do
      response =
        conn
        |> put("/api/v1/push/subscription", %{"data" => %{"policy" => "all"}})
        |> json_response(404)

      assert response["error"] =~ "Not found"
    end

    test "returns 401 without authorization", %{} do
      response =
        unauthenticated_conn()
        |> put("/api/v1/push/subscription", %{"data" => %{"policy" => "all"}})
        |> json_response(401)

      assert response["error"] =~ "You need to login first." or response["error"] =~ "invalid"
    end
  end

  describe "DELETE /api/v1/push/subscription" do
    test "deletes the subscription", %{conn: conn} do
      create_subscription(conn)

      conn
      |> delete("/api/v1/push/subscription")
      |> json_response(200)

      response =
        conn
        |> get("/api/v1/push/subscription")
        |> json_response(404)

      assert response["error"] =~ "Not found"
    end

    test "returns 404 when no subscription exists", %{conn: conn} do
      response =
        conn
        |> delete("/api/v1/push/subscription")
        |> json_response(404)

      assert response["error"] =~ "Not found"
    end

    test "returns 401 without authorization", %{} do
      response =
        unauthenticated_conn()
        |> delete("/api/v1/push/subscription")
        |> json_response(401)

      assert response["error"] =~ "You need to login first." or response["error"] =~ "invalid"
    end
  end
end
