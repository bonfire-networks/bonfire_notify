defmodule Bonfire.Notify.NativePush do
  @moduledoc """
  Registers and manages native APNs/FCM push devices.

  Also the native delivery channel: `configured?/0`, `targets/2`, `target/2` and `deliver/3` implement `Bonfire.Notify.Channel` for one recipient and one device at a time, which is what a delivery job asks for.

  Every query here is scoped to the native gateways, because a person's links point at whatever devices they have registered and a browser's endpoint is not ours to send to.
  """

  @behaviour Bonfire.Notify.Channel

  use Bonfire.Common.Utils
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.NativePushDevice
  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription

  @doc """
  Registers a native push device for a user.

  Finds or creates the device row by its token, then links this user to it. Two accounts on one phone get one device row and a link each, so registering can never take the device away from whoever registered it first.
  """
  def register(user, attrs) do
    user_id = uid(user)
    attrs = normalize_attrs(attrs)
    {link_attrs, device_attrs} = split_attrs(attrs)

    with {:ok, device} <- NativePushDevice.find_or_create(device_attrs),
         {:ok, link} <- UserPushSubscription.upsert(user_id, device.id, link_attrs) do
      {:ok, %{link | push_device: device}}
    end
  end

  defp split_attrs(attrs) do
    {Map.take(attrs, [:policy]),
     Map.take(attrs, [:provider, :token, :platform, :device_name, :active])}
  end

  @doc "Lists a user's active native devices, as their own subscriptions to them."
  def list_devices(user) do
    user_id = uid(user)

    active_native_links()
    |> where([us], us.id == ^user_id)
    |> repo().many()
  end

  @doc """
  Every active device these people have that will take this kind of notification, in one query.

  Two things on the link can narrow it, both already loaded with the row: a subscription whose policy is `none` takes nothing at all, and one registered through the Mastodon API takes only the types that client asked for, which is that API's own rule and lives with it. A subscription from anywhere else carries no such map, so the person's settings alone decide.
  """
  @impl Bonfire.Notify.Channel
  def targets(user_ids, verb \\ nil) when is_list(user_ids) do
    active_native_links()
    |> where([us], us.id in ^user_ids)
    |> repo().many()
    |> Enum.filter(&takes?(&1, verb))
    |> Enum.map(&%{user_id: &1.id, target_id: &1.push_device_id})
  end

  defp takes?(link, verb) do
    link.policy != "none" and Bonfire.Notify.API.MastoPushAdapter.accepts?(link, verb)
  end

  @doc """
  Re-reads one subscription at delivery time, as this person's link to the device.

  The link rather than the device row, because a phone can be shared: delivering to the device alone would hand someone else's notification to whoever is logged in now. A device that was deregistered, or that a rejected send marked inactive, is simply not found.
  """
  @impl Bonfire.Notify.Channel
  def target(push_device_id, user_id) when is_binary(push_device_id) and is_binary(user_id) do
    active_native_links()
    |> where([us], us.id == ^user_id and us.push_device_id == ^push_device_id)
    |> repo().one()
    |> case do
      nil -> {:error, :inactive}
      link -> {:ok, link}
    end
  end

  @doc """
  Sends one notification's content to one device, and records what came back.

  A token the gateway has rejected as gone is deactivated and cancelled, since it will never work again; anything else is worth another attempt. An instance with no native adapter configured cancels rather than erroring, because no amount of retrying configures one.
  """
  @impl Bonfire.Notify.Channel
  def deliver(
        %UserPushSubscription{push_device: %PushDevice{} = device} = link,
        content,
        opts \\ []
      ) do
    adapter = native_push_adapter()

    if adapter_configured?(adapter) do
      # shaped and serialised at the wire, where what is listening on this device is known
      case Bonfire.Notify.Channel.payload_json(link, content) do
        {:ok, payload} ->
          [device]
          |> adapter.send_notifications(payload, Keyword.take(opts, [:ttl, :urgency, :topic]))
          |> List.wrap()
          |> List.first()
          |> handle_delivery_result(device)

        {:error, reason} ->
          # nothing this client could read, so there is nothing to retry
          {:cancel, reason}
      end
    else
      {:cancel, :native_push_not_configured}
    end
  end

  defp handle_delivery_result({:ok, _device, _response}, device) do
    PushDevice.mark_status(device, :success)
    :ok
  end

  defp handle_delivery_result({:error, _device, reason}, device)
       when reason in [:expired, :unregistered, :invalid_token] do
    PushDevice.mark_status(device, {:expired, reason})
    {:cancel, :inactive}
  end

  defp handle_delivery_result({:error, _device, reason}, device) do
    PushDevice.mark_status(device, {:error, reason})
    {:error, reason}
  end

  defp handle_delivery_result(other, device) do
    PushDevice.mark_status(device, {:error, other})
    error(other, "Native push adapter answered in a shape we don't understand")
    {:error, :unexpected_adapter_result}
  end

  @doc """
  Removes a user's subscription to a device, leaving the device for anyone else who uses it.
  """
  def remove_device(user, push_device_id),
    do: UserPushSubscription.unsubscribe(uid(user), push_device_id)

  @doc "Returns whether a native push adapter is configured."
  @impl Bonfire.Notify.Channel
  def configured? do
    adapter = native_push_adapter()
    adapter_configured?(adapter)
  end

  defp active_native_links do
    providers = NativePushDevice.providers()

    from(us in UserPushSubscription,
      join: d in PushDevice,
      on: d.id == us.push_device_id,
      where: d.provider in ^providers and d.active == true,
      preload: [push_device: d]
    )
  end

  defp native_push_adapter do
    Application.get_env(:bonfire_notify, :native_push_adapter)
  end

  defp adapter_configured?(nil), do: false

  defp adapter_configured?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :send_notifications, 3)
  end

  defp normalize_attrs(attrs) do
    attrs
    |> atomize_allowed()
    |> Map.update(:provider, nil, &normalize_string/1)
    |> Map.update(:platform, nil, &normalize_string/1)
  end

  defp atomize_allowed(attrs) do
    %{}
    |> maybe_take(attrs, :provider, "provider")
    |> maybe_take(attrs, :token, "token")
    |> maybe_take(attrs, :platform, "platform")
    |> maybe_take(attrs, :device_name, "device_name")
    |> maybe_take(attrs, :device_name, "deviceName")
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
end
