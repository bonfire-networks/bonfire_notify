defmodule Bonfire.Notify.NativePush do
  @moduledoc """
  Registers and manages native APNs/FCM push device tokens.
  """

  use Bonfire.Common.Utils
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.NativePushDevice

  @doc "Registers or updates a native push device for a user."
  def register(%{} = user, attrs), do: register(id(user), attrs)

  def register(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs = normalize_attrs(attrs)
    provider = attrs[:provider]
    token = attrs[:token]

    existing =
      if is_binary(provider) and is_binary(token) do
        NativePushDevice.get_by_provider_and_token(provider, token)
      end

    existing = existing || %NativePushDevice{}

    existing
    |> NativePushDevice.changeset(attrs, user_id: user_id)
    |> repo().insert_or_update()
  end

  @doc "Lists active native push devices for a user."
  def list_devices(%{} = user), do: list_devices(id(user))

  def list_devices(user_id) when is_binary(user_id) do
    from(d in NativePushDevice,
      where: d.user_id == ^user_id and d.active == true,
      order_by: [desc: d.updated_at, desc: d.inserted_at]
    )
    |> repo().many()
  end

  @doc "Removes a native push device belonging to a user."
  def remove_device(%{} = user, device_id), do: remove_device(id(user), device_id)

  def remove_device(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    case repo().one(
           from(d in NativePushDevice,
             where: d.user_id == ^user_id and d.id == ^device_id
           )
         ) do
      nil -> {:error, :not_found}
      device -> repo().delete(device)
    end
  end

  @doc "Marks a native push device inactive by provider token."
  def deactivate(provider, token) when is_binary(provider) and is_binary(token) do
    case NativePushDevice.get_by_provider_and_token(provider, token) do
      nil ->
        {:error, :not_found}

      device ->
        device
        |> NativePushDevice.changeset(%{active: false, last_status: :expired})
        |> repo().update()
    end
  end

  @doc "Returns whether a native push adapter is configured."
  def configured? do
    adapter = native_push_adapter()
    adapter_configured?(adapter)
  end

  @doc "Sends a message through the configured native push adapter."
  def send_native_push(user_ids, message, opts \\ [])
      when is_list(user_ids) or is_binary(user_ids) do
    devices =
      user_ids
      |> List.wrap()
      |> list_active_devices()
      |> filter_devices_by_preferences(opts)

    case devices do
      [] ->
        {:error, :no_native_push_devices}

      devices ->
        adapter = native_push_adapter()

        if adapter_configured?(adapter) do
          opts = Keyword.drop(opts, [:notify_category, :from_id])
          results = adapter.send_notifications(devices, message, opts)

          update_device_statuses(results)
          results
        else
          {:error, :native_push_not_configured}
        end
    end
  end

  defp list_active_devices(user_ids) do
    from(d in NativePushDevice,
      where: d.user_id in ^user_ids and d.active == true
    )
    |> repo().many()
  end

  defp filter_devices_by_preferences(devices, opts) do
    alert_key = opts[:notify_category] && masto_alert_key(opts[:notify_category])
    from_id = opts[:from_id] && Bonfire.Common.Enums.id(opts[:from_id])

    Enum.filter(devices, fn device ->
      passes_alerts?(device, alert_key) and passes_policy?(device, from_id)
    end)
  end

  defp passes_alerts?(_device, nil), do: true

  defp passes_alerts?(device, alert_key) do
    NativePushDevice.effective_alerts(device.alerts)
    |> Map.get(alert_key, true) == true
  end

  defp passes_policy?(device, from_id) do
    case NativePushDevice.effective_policy(device.policy) do
      "all" -> true
      "none" -> false
      "followed" -> from_id != nil and follows?(device.user_id, from_id)
      "follower" -> from_id != nil and follows?(from_id, device.user_id)
      _ -> true
    end
  end

  defp follows?(subject_id, object_id) do
    !!Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Graph.Follows,
      :following?,
      [subject_id, object_id],
      fallback_return: false
    )
  end

  defp masto_alert_key(:likes), do: "favourite"
  defp masto_alert_key(:boosts), do: "reblog"
  defp masto_alert_key(:follows), do: "follow"
  defp masto_alert_key(:messages), do: "mention"
  defp masto_alert_key(:replies_and_mentions), do: "mention"
  defp masto_alert_key(_), do: nil

  defp native_push_adapter do
    Application.get_env(:bonfire_notify, :native_push_adapter)
  end

  defp adapter_configured?(nil), do: false

  defp adapter_configured?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :send_notifications, 3)
  end

  defp update_device_statuses(results) when is_list(results) do
    Enum.each(results, fn
      {:ok, %NativePushDevice{} = device, _response} ->
        update_device_status(device, :success)

      {:ok, %NativePushDevice{} = device} ->
        update_device_status(device, :success)

      {:error, %NativePushDevice{} = device, reason}
      when reason in [:expired, :unregistered, :invalid_token] ->
        update_device_status(device, {:expired, reason})

      {:error, %NativePushDevice{} = device, reason} ->
        update_device_status(device, {:error, reason})

      _ ->
        :ok
    end)
  end

  defp update_device_statuses(_results), do: :ok

  defp update_device_status(%NativePushDevice{id: id}, :success) do
    from(d in NativePushDevice, where: d.id == ^id)
    |> repo().update_all(
      set: [
        last_status: :success,
        last_used_at: now(),
        last_error: nil,
        active: true
      ]
    )
  end

  defp update_device_status(%NativePushDevice{id: id}, {:expired, reason}) do
    from(d in NativePushDevice, where: d.id == ^id)
    |> repo().update_all(
      set: [
        last_status: :expired,
        last_used_at: now(),
        last_error: inspect(reason),
        active: false
      ]
    )
  end

  defp update_device_status(%NativePushDevice{id: id}, {:error, reason}) do
    from(d in NativePushDevice, where: d.id == ^id)
    |> repo().update_all(
      set: [
        last_status: :error,
        last_used_at: now(),
        last_error: inspect(reason)
      ]
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp normalize_attrs(attrs) do
    attrs
    |> atomize_allowed()
    |> Map.update(:provider, nil, &normalize_string/1)
    |> Map.update(:platform, nil, &normalize_string/1)
    |> Map.update(:alerts, nil, &normalize_alerts/1)
  end

  defp atomize_allowed(attrs) do
    %{}
    |> maybe_take(attrs, :provider, "provider")
    |> maybe_take(attrs, :token, "token")
    |> maybe_take(attrs, :platform, "platform")
    |> maybe_take(attrs, :device_name, "device_name")
    |> maybe_take(attrs, :device_name, "deviceName")
    |> maybe_take(attrs, :alerts, "alerts")
    |> maybe_take(attrs, :policy, "policy")
    |> maybe_take(attrs, :active, "active")
  end

  defp maybe_take(out, attrs, key, string_key) do
    cond do
      Map.has_key?(attrs, key) -> Map.put(out, key, Map.get(attrs, key))
      Map.has_key?(attrs, string_key) -> Map.put(out, key, Map.get(attrs, string_key))
      true -> out
    end
  end

  defp normalize_string(value) when is_binary(value), do: String.downcase(value)
  defp normalize_string(value), do: value

  defp normalize_alerts(nil), do: nil

  defp normalize_alerts(alerts) when is_map(alerts) do
    alerts
    |> Enum.reduce(%{}, fn
      {:admin_sign_up, value}, acc -> Map.put(acc, "admin.sign_up", value)
      {"admin_sign_up", value}, acc -> Map.put(acc, "admin.sign_up", value)
      {:admin_report, value}, acc -> Map.put(acc, "admin.report", value)
      {"admin_report", value}, acc -> Map.put(acc, "admin.report", value)
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  defp normalize_alerts(other), do: other
end
