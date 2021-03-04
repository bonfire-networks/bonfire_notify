defmodule Bonfire.Notify.WebPush.Adapter do
  @moduledoc """
  The behaviour for web push adapters.
  """

  alias Bonfire.Notify.WebPush.Payload
  alias Bonfire.Notify.WebPush.Subscription

  @doc """
  Sends a web push request to the subscription.
  """
  @callback make_request(Payload.t(), Subscription.t()) ::
              {:ok, any()} | {:error, atom()} | no_return()
end
