defmodule Bonfire.Notify.Test.FakeHelpers do
  alias Bonfire.Data.Identity.Account
  alias Bonfire.Me.Fake
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Users

  import ExUnit.Assertions

  import Bonfire.Common.Config, only: [repo: 0]

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
