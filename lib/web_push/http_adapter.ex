defmodule Bonfire.Notify.WebPush.HttpAdapter do
  @moduledoc """
  The HTTP client for sending real web pushes.
  """

  alias Bonfire.Notify.WebPush.Payload

  @behaviour Bonfire.Notify.WebPush.Adapter

  @impl true
  def make_request(payload, subscription) do
    IO.inspect(payload: payload)
    IO.inspect(subscription: subscription)

    payload
    |> Payload.serialize()
    |> WebPushEncryption.send_web_push(subscription)
  end
end
