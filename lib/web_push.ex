defmodule Bonfire.Notify.WebPush do
  @moduledoc """
  Manages web push subscriptions and sends notifications using ExNudge.

  Also the web-push delivery channel: `configured?/0`, `targets/2`, `target/2` and `deliver/3` implement `Bonfire.Notify.Channel` for one recipient and one browser at a time, which is what a delivery job asks for.

  Every query here is scoped to `Bonfire.Notify.WebPushDevice.providers/0`, because a person's subscriptions point at whatever devices they have registered and a phone's APNs token is not ours to send to. That set has two members: a client of ours, and a Mastodon client reached identically but sent a payload of its own shape.
  """

  @behaviour Bonfire.Notify.Channel

  use Bonfire.Common.Utils
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.Channel
  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription
  alias Bonfire.Notify.WebPushDevice

  @doc """
  Registers a push subscription for a user.

  Finds or creates the device row by endpoint, then links the user to it, with their own preferences if any came along.
  """
  @spec subscribe(String.t(), map() | String.t()) ::
          {:ok, UserPushSubscription.t()} | {:error, Ecto.Changeset.t() | atom()}
  def subscribe(user_id, data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed_data} -> subscribe(user_id, parsed_data)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def subscribe(user_id, %{} = data) do
    case WebPushDevice.parse_subscription_data(data) do
      {:ok, parsed_attrs} ->
        {user_attrs, device_attrs} = split_attrs(parsed_attrs)

        with {:ok, device} <- WebPushDevice.find_or_create(device_attrs),
             {:ok, user_sub} <- UserPushSubscription.upsert(user_id, device.id, user_attrs) do
          {:ok, %{user_sub | push_device: device}}
        end

      {:error, reason} ->
        {:error,
         %PushDevice{}
         |> WebPushDevice.changeset(%{})
         |> Ecto.Changeset.add_error(:base, to_string(reason))}
    end
  end

  defp split_attrs(parsed) do
    # no alerts: subscribing says where to reach someone, and what to send them is a per-verb, per-channel setting on their account. Only `Bonfire.Notify.API.MastoPushAdapter` stores an alerts map, because only that API's rules need one
    user_attrs = Map.take(parsed, [:policy])

    device_attrs =
      Map.take(parsed, [:address, :auth_key, :p256dh_key, :device_agent, :device_name])

    {user_attrs, device_attrs}
  end

  @doc """
  Lists active web subscriptions for the given user ids, each preloaded with its device.
  """
  def list_subscriptions(user_ids) when is_list(user_ids) do
    active_web_links()
    |> where([us], us.id in ^user_ids)
    |> repo().many()
  end

  def list_subscriptions(user_id) when is_binary(user_id) do
    list_subscriptions([user_id])
  end

  @doc "Every active web subscription on the instance, or every inactive one."
  def list_all_subscriptions(active? \\ true) do
    from(us in UserPushSubscription,
      join: d in PushDevice,
      on: d.id == us.push_device_id,
      where: d.provider in ^WebPushDevice.providers() and d.active == ^active?,
      preload: [push_device: d]
    )
    |> repo().many()
  end

  @doc "Whether web push can be sent at all on this instance, meaning VAPID keys are configured."
  @impl Bonfire.Notify.Channel
  def configured?, do: Bonfire.Notify.enabled?()

  @doc """
  Every browser these people have subscribed that will take this kind of notification, in one query.

  Two things on the link can narrow it, both already loaded with the row, so neither costs a query: a subscription whose policy is `none` takes nothing at all, and one a Mastodon client created takes only the types that client asked for, which is that API's own rule and lives with it. A subscription from anywhere else carries no such map, so the person's settings alone decide.
  """
  @impl Bonfire.Notify.Channel
  def targets(user_ids, verb \\ nil) when is_list(user_ids) do
    list_subscriptions(user_ids)
    |> Enum.filter(&takes?(&1, verb))
    |> Enum.map(&%{user_id: &1.id, target_id: &1.push_device_id})
  end

  defp takes?(link, verb) do
    link.policy != "none" and Bonfire.Notify.API.MastoPushAdapter.accepts?(link, verb)
  end

  @doc """
  Re-reads one subscription at delivery time, as this person's link to the device.

  The link rather than the device row, because a browser can be shared: delivering to the device alone would hand someone else's notification to whoever holds the browser now. A device that rotated its endpoint or was pruned is simply not found.
  """
  @impl Bonfire.Notify.Channel
  def target(push_device_id, user_id) when is_binary(push_device_id) and is_binary(user_id) do
    active_web_links()
    |> where([us], us.id == ^user_id and us.push_device_id == ^push_device_id)
    |> repo().one()
    |> case do
      nil -> {:error, :inactive}
      link -> {:ok, link}
    end
  end

  @doc """
  Sends one notification's content to one browser, and records what came back.

  The response decides the job's fate rather than just being logged: a gone endpoint is deactivated and cancelled (there is nothing to retry), a rate limit is a snooze, a server error is worth retrying, and a rejected request means our own configuration is wrong, so retrying it five times only delays the same failure.
  """
  @impl Bonfire.Notify.Channel
  def deliver(
        %UserPushSubscription{push_device: %PushDevice{} = device} = link,
        content,
        opts \\ []
      ) do
    # shaped and serialised at the wire, because which shape this endpoint's client can read is known here and nowhere earlier
    case Channel.payload_json(link, content) do
      {:ok, payload} ->
        device
        |> WebPushDevice.to_ex_nudge_subscription(link.id)
        |> ex_nudge_module().send_notification(
          payload,
          Keyword.take(opts, [:ttl, :urgency, :topic])
        )
        |> handle_delivery_result(device)

      {:error, reason} ->
        # nothing this client could read, so there is nothing to retry
        {:cancel, reason}
    end
  end

  defp handle_delivery_result({:ok, %{status_code: status}}, device) when status in 200..299 do
    PushDevice.mark_status(device, :success)
    :ok
  end

  defp handle_delivery_result({:error, :subscription_expired}, device),
    do: deactivate_and_cancel(device, :subscription_expired)

  defp handle_delivery_result({:error, {:http_error, status}}, device)
       when status in [404, 410],
       do: deactivate_and_cancel(device, {:http_error, status})

  defp handle_delivery_result({:error, :payload_too_large}, device) do
    # our own payload is too big for this push service, so it will be too big next time too
    PushDevice.mark_status(device, {:error, :payload_too_large})
    error(:payload_too_large, "Web push payload rejected as too large")
    {:cancel, :payload_too_large}
  end

  defp handle_delivery_result({:error, {:http_error, 429}}, device) do
    PushDevice.mark_status(device, {:error, {:http_error, 429}})
    {:snooze, snooze_seconds()}
  end

  defp handle_delivery_result({:error, {:http_error, status}}, device) when status >= 500 do
    PushDevice.mark_status(device, {:error, {:http_error, status}})
    {:error, {:http_error, status}}
  end

  defp handle_delivery_result({:error, {:http_error, status}}, device) do
    PushDevice.mark_status(device, {:error, {:http_error, status}})

    error(
      {:http_error, status},
      "Web push rejected our request, so check the VAPID configuration"
    )

    {:cancel, {:http_error, status}}
  end

  defp handle_delivery_result({:error, {:request_failed, reason}}, device) do
    PushDevice.mark_status(device, {:error, {:request_failed, reason}})
    {:error, {:request_failed, reason}}
  end

  defp handle_delivery_result({:error, reason}, device) do
    # anything else is ours rather than the push service's: no keys, an unencryptable payload
    PushDevice.mark_status(device, {:error, reason})
    error(reason, "Could not send a web push, so cancelling rather than retrying it")
    {:cancel, reason}
  end

  defp deactivate_and_cancel(device, reason) do
    PushDevice.mark_status(device, {:expired, reason})
    {:cancel, :inactive}
  end

  defp snooze_seconds do
    Config.get([Bonfire.Notify.Channel, :snooze_seconds], 60,
      name: l("Push rate-limit snooze"),
      description: l("How long to wait before retrying a delivery a push service rate-limited.")
    )
  end

  defp active_web_links do
    from(us in UserPushSubscription,
      join: d in PushDevice,
      on: d.id == us.push_device_id,
      where: d.provider in ^WebPushDevice.providers() and d.active == true,
      preload: [push_device: d]
    )
  end

  @doc """
  Turns push off for one person on one browser, by that browser's endpoint.

  Their subscription goes; the device row only goes when nobody is subscribed to it any more. That order is what makes a shared browser safe: deleting the device because one account turned push off would silently unsubscribe every other account signed into it.

  Answers `:last_one` when the device went too, since that is when the browser's own subscription is worth dropping, and `:others_remain` when it did not.
  """
  def unsubscribe(user_id, endpoint) when is_binary(user_id) and is_binary(endpoint) do
    with %PushDevice{} = device <- WebPushDevice.get_by_endpoint(endpoint),
         {:ok, _gone} <- UserPushSubscription.unsubscribe(user_id, device.id) do
      if repo().exists?(from(us in UserPushSubscription, where: us.push_device_id == ^device.id)) do
        {:ok, :others_remain}
      else
        repo().delete(device)
        {:ok, :last_one}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Removes a browser's device row by endpoint, and with it everyone's links to it.

  For a push service telling us an endpoint is gone, which is about the device rather than about anyone's choice. A person turning push off is `unsubscribe/2`.
  """
  def remove_subscription_by_endpoint(endpoint) when is_binary(endpoint) do
    from(d in PushDevice,
      where: d.provider in ^WebPushDevice.providers() and d.address == ^endpoint
    )
    |> repo().delete_all()
  end

  @doc """
  Removes a device row by its id, and with it everyone's links to it.
  """
  def remove_subscription(push_device_id) when is_binary(push_device_id) do
    case repo().get(PushDevice, push_device_id) do
      nil -> {:error, :subscription_not_found}
      device -> repo().delete(device)
    end
  end

  @doc """
  Gets the user's most recently used web subscription.
  """
  def get_user_subscription(user_id) do
    active_web_links()
    |> where([us], us.id == ^user_id)
    |> order_by([us, d], desc: d.last_used_at)
    |> limit(1)
    |> repo().one()
  end

  @doc """
  Helper to format a push notification message.
  """
  def format_push_message(title, body, opts \\ []) do
    opts
    |> Map.new()
    |> Map.merge(%{title: title, body: body})
    |> Channel.push_payload()
    |> Jason.encode!()
  end

  def ex_nudge_module do
    if Application.get_env(:bonfire_notify, :use_ex_nudge_mock) do
      ExNudge.Mock
    else
      ExNudge
    end
  end

  def generate_keys_env do
    keys = ExNudge.VAPID.generate_vapid_keys()

    IO.puts("""
    WEB_PUSH_PUBLIC_KEY=#{keys.public_key}
    WEB_PUSH_PRIVATE_KEY=#{keys.private_key}
    """)

    :ok
  end
end
