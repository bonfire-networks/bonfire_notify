defmodule Bonfire.Notifications.WebPush.HttpAdapter do
  @moduledoc """
  The HTTP client for sending real web pushes.
  """

  alias Bonfire.Notifications.WebPush.Payload

  @behaviour Bonfire.Notifications.WebPush.Adapter

  @impl true
  def make_request(payload, subscription) do
    payload
    |> Payload.serialize()
    |> WebPushEncryption.send_web_push(subscription)
  end
end
