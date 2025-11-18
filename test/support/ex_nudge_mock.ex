defmodule ExNudge.Mock do
  @moduledoc """
  Simple mock for ExNudge in tests. 

  Set the expected behavior using Application config:

      Application.put_env(:bonfire_notify, :ex_nudge_mock_response, :success)
      # or
      Application.put_env(:bonfire_notify, :ex_nudge_mock_response, :expired)
      # or
      Application.put_env(:bonfire_notify, :ex_nudge_mock_response, {:error, 500})
  """

  def send_notifications(subscriptions, _message, _opts \\ []) do
    response_type = Application.get_env(:bonfire_notify, :ex_nudge_mock_response, :success)

    Enum.map(subscriptions, fn sub ->
      case response_type do
        :success ->
          {:ok, sub, %{status_code: 201, body: "Success"}}

        :expired ->
          {:error, sub, :subscription_expired}

        {:error, status_code} ->
          {:error, sub, %{status_code: status_code, body: "Error"}}

        _ ->
          {:ok, sub, %{status_code: 201, body: "Success"}}
      end
    end)
  end
end
