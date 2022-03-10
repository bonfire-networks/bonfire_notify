defmodule Bonfire.Notify.Test.FakeHelpers do

  alias Bonfire.Data.Identity.Account
  alias Bonfire.Me.Fake
  alias Bonfire.Me.{Accounts, Users}

  import ExUnit.Assertions

  import Bonfire.Common.Config, only: [repo: 0]


  def valid_push_subscription_data(endpoint \\ "https://endpoint.test") do
    """
      {
        "endpoint": "#{endpoint}",
        "expirationTime": null,
        "keys": {
          "p256dh": "p256dh",
          "auth": "auth"
        }
      }
    """
  end

end
