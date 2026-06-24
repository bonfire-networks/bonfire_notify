defmodule Bonfire.Notify.Test.NativePushAdapter do
  @moduledoc false

  def send_notifications(devices, message, opts) do
    if pid = Application.get_env(:bonfire_notify, :native_push_test_pid) do
      send(pid, {:native_push_send, devices, message, opts})
    end

    case Application.get_env(:bonfire_notify, :native_push_test_result, :ok) do
      :ok ->
        Enum.map(devices, &{:ok, &1, :sent})

      :expired ->
        Enum.map(devices, &{:error, &1, :expired})

      {:error, reason} ->
        Enum.map(devices, &{:error, &1, reason})

      result_fun when is_function(result_fun, 1) ->
        result_fun.(devices)
    end
  end
end
