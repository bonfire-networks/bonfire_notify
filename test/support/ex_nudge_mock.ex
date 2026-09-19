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

  @doc """
  One subscription at a time, as a delivery job sends.

  Answers in the shapes `ExNudge.send_notification/3` really returns, since what a delivery job does next is decided entirely by which of them comes back: a response for 2xx, a bare reason for the errors ExNudge names itself, and `{:http_error, status}` for every other status.
  """
  def send_notification(subscription, message, opts \\ []) do
    if pid = Application.get_env(:bonfire_notify, :ex_nudge_mock_pid) do
      send(pid, {:web_push_sent, subscription, message, opts})
    end

    case Application.get_env(:bonfire_notify, :ex_nudge_mock_response, :success) do
      :success -> {:ok, %{status_code: 201, body: "Success"}}
      :expired -> {:error, :subscription_expired}
      :payload_too_large -> {:error, :payload_too_large}
      {:http_error, status} -> {:error, {:http_error, status}}
      {:request_failed, reason} -> {:error, {:request_failed, reason}}
      {:error, reason} -> {:error, reason}
      _ -> {:ok, %{status_code: 201, body: "Success"}}
    end
  end
end
