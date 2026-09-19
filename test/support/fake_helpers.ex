defmodule Bonfire.Notify.Test.FakeHelpers do
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Bonfire.Me.Fake
  alias Bonfire.Me.Users

  def fake_admin!(account \\ %{}, attrs \\ %{}, opts \\ []) do
    user = Fake.fake_user!(account, attrs, opts)
    {:ok, user} = Users.make_admin(user)
    user
  end

  # Helper functions
  def valid_push_subscription_data(endpoint) do
    valid_push_subscription_map(endpoint)
    |> Jason.encode!()
  end

  def valid_push_subscription_map(endpoint) do
    # Generate valid base64-encoded keys
    # These are example values that match the Web Push spec format
    %{
      "endpoint" => endpoint,
      "keys" => %{
        # Real p256dh keys are 65 bytes, base64url-encoded (87 chars)
        "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
        # Real auth keys are 16 bytes, base64url-encoded (22 chars)  
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }
    }
  end

  @doc """
  Makes native push a configured channel for this test, answering with `result`.

  A channel an instance can't send on has no targets and gets no delivery jobs, so a test about
  delivery has to configure one, the same as an instance does.

  Sends `{:native_push_send, devices, message, opts}` here, so a test can assert what went out.
  """
  def configure_native_push(result \\ :ok) do
    put_test_env(:bonfire_notify, %{
      native_push_adapter: Bonfire.Notify.Test.NativePushAdapter,
      native_push_test_pid: self(),
      native_push_test_result: result
    })
  end

  @doc """
  Makes web push a configured channel for this test, answering with `response`.

  VAPID keys are what `configured?/0` reads, and the mock is what stands in for the push service, so
  both are needed: keys alone would try to reach a real endpoint.

  Sends `{:web_push_sent, subscription, message, opts}` here, so a test can assert what went out.
  """
  def configure_web_push(response \\ :success) do
    put_test_env(:bonfire_notify, %{
      use_ex_nudge_mock: true,
      ex_nudge_mock_response: response,
      ex_nudge_mock_pid: self()
    })

    put_test_env(:ex_nudge, %{
      vapid_public_key: "test-vapid-public-key",
      vapid_private_key: "test-vapid-private-key"
    })
  end

  @doc """
  An OAuth access token for a user, as a Mastodon client would hold after authorising.

  Real rather than faked, because what a Mastodon push payload carries is the token's own value, and delivery looks it up while it is still valid: a made-up id would only prove the lookup fails.
  """
  def fake_oauth_token!(user, scope \\ "read write push") do
    {:ok, client} =
      Bonfire.OpenID.Provider.ClientApps.new(%{
        id: Faker.UUID.v4(),
        name: "test-push-app-#{System.unique_integer([:positive])}",
        redirect_uris: ["http://localhost:4000/oauth/callback"]
      })

    {:ok, token} =
      Boruta.Ecto.AccessTokens.create(
        %{
          client: Boruta.Ecto.OauthMapper.to_oauth_schema(client),
          sub: Bonfire.Common.Types.uid(user),
          scope: scope
        },
        []
      )

    token
  end

  @doc "A conn authenticated as a Mastodon client would be, with a bearer token belonging to `user`."
  def masto_authenticated_conn(user) do
    token = fake_oauth_token!(user)

    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token.value}")
  end

  # sets app env for the duration of one test, putting back whatever was there, since app env is global and a leaked key makes another test fail somewhere else
  defp put_test_env(app, values) do
    previous = Map.new(values, fn {key, _} -> {key, Application.get_env(app, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(app, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(app, key)
        {key, value} -> Application.put_env(app, key, value)
      end)
    end)
  end

  # def valid_push_subscription_data(endpoint \\ "https://endpoint.test") do
  #   """
  #     {
  #       "endpoint": "#{endpoint}",
  #       "expirationTime": null,
  #       "keys": {
  #         "p256dh": "p256dh",
  #         "auth": "auth"
  #       }
  #     }
  #   """
  # end
end
