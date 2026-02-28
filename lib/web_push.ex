defmodule Bonfire.Notify.WebPush do
  @moduledoc """
  Manages web push subscriptions and sends notifications using ExNudge.
  """

  use Bonfire.Common.Utils
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.PushSubscription
  alias Bonfire.Notify.UserPushSubscription

  @doc """
  Registers a push subscription for a user.

  Finds or creates a PushSubscription by endpoint, then links the user
  via UserPushSubscription (with optional alerts/policy preferences).
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
    case PushSubscription.parse_subscription_data(data) do
      {:ok, parsed_attrs} ->
        # Split device-level attrs from user-level attrs
        {user_attrs, device_attrs} = split_attrs(parsed_attrs)

        with {:ok, push_sub} <- PushSubscription.find_or_create_by_endpoint(device_attrs),
             {:ok, user_sub} <- find_or_create_user_link(user_id, push_sub.id, user_attrs) do
          {:ok, %{user_sub | push_subscription: push_sub}}
        end

      {:error, reason} ->
        {:error,
         %PushSubscription{}
         |> PushSubscription.changeset(%{})
         |> Ecto.Changeset.add_error(:base, to_string(reason))}
    end
  end

  defp split_attrs(parsed) do
    user_attrs = Map.take(parsed, [:alerts, :policy])

    device_attrs =
      Map.take(parsed, [
        :endpoint,
        :auth_key,
        :p256dh_key,
        :platform,
        :user_agent,
        :device_name
      ])

    {user_attrs, device_attrs}
  end

  defp find_or_create_user_link(user_id, push_subscription_id, user_attrs) do
    case repo().one(
           from(us in UserPushSubscription,
             where: us.id == ^user_id and us.push_subscription_id == ^push_subscription_id
           )
         ) do
      nil ->
        %UserPushSubscription{id: user_id}
        |> UserPushSubscription.changeset(
          Map.put(user_attrs, :push_subscription_id, push_subscription_id)
        )
        |> repo().insert()

      existing ->
        if user_attrs == %{} do
          {:ok, existing}
        else
          existing
          |> UserPushSubscription.changeset(user_attrs)
          |> repo().update()
        end
    end
  end

  @doc """
  Fetches all subscriptions for a list of user ids.
  Returns a map of user_id => list of ExNudge.Subscription structs.
  Only returns active subscriptions.
  """
  @spec get_subscriptions([String.t()]) :: %{
          optional(String.t()) => [ExNudge.Subscription.t()]
        }
  def get_subscriptions(user_ids) when is_list(user_ids) do
    list_subscriptions_with_push(user_ids)
    |> Enum.group_by(
      fn {user_sub, _push_sub} -> user_sub.id end,
      fn {user_sub, push_sub} ->
        PushSubscription.to_ex_nudge_subscription(push_sub, user_sub.id)
      end
    )
  end

  def get_subscriptions(user_id) when is_binary(user_id) do
    get_subscriptions([user_id])
  end

  @doc """
  Lists active UserPushSubscription records for the given user IDs,
  preloaded with their PushSubscription.
  """
  def list_subscriptions(user_ids) when is_list(user_ids) do
    from(us in UserPushSubscription,
      join: ps in PushSubscription,
      on: ps.id == us.push_subscription_id,
      where: us.id in ^user_ids and ps.active == true,
      preload: [push_subscription: ps]
    )
    |> repo().many()
  end

  def list_subscriptions(user_id) when is_binary(user_id) do
    list_subscriptions([user_id])
  end

  defp list_subscriptions_with_push(user_ids) do
    from(us in UserPushSubscription,
      join: ps in PushSubscription,
      on: ps.id == us.push_subscription_id,
      where: us.id in ^user_ids and ps.active == true,
      select: {us, ps}
    )
    |> repo().many()
  end

  def list_all_subscriptions(active? \\ true) do
    from(us in UserPushSubscription,
      join: ps in PushSubscription,
      on: ps.id == us.push_subscription_id,
      where: ps.active == ^active?,
      preload: [push_subscription: ps]
    )
    |> repo().many()
  end

  @doc """
  Sends a web push notification to all subscriptions for a user or multiple users.
  Uses ExNudge to handle the actual sending.

  The IDs can be either user IDs or notification feed IDs - both are resolved
  to find matching push subscriptions.
  """
  def send_web_push(user_ids, message, opts \\ [])
      when is_list(user_ids) or is_binary(user_ids) do
    ids = List.wrap(user_ids)

    # First try direct lookup by user_id
    direct_subscriptions =
      get_subscriptions(ids)
      |> Map.values()
      |> List.flatten()

    subscriptions =
      if direct_subscriptions != [] do
        # FIXME: what if some ids matched and others didn't?
        debug(direct_subscriptions, "found subscriptions by user_id")
        direct_subscriptions
      else
        # If no direct matches, try resolving as notification feed IDs
        # FIXME: we shouldn't simply notify all users that feed IDs belong to, instead taking into alerts categories somehow
        resolved_user_ids = resolve_feed_ids_to_user_ids(ids)
        debug(resolved_user_ids, "resolved feed IDs to user IDs")

        if resolved_user_ids != [] do
          get_subscriptions(resolved_user_ids)
          |> Map.values()
          |> List.flatten()
        else
          []
        end
      end

    case subscriptions do
      [] ->
        {:error, :no_subscriptions}

      subscriptions ->
        send_web_push_to_subscriptions(subscriptions, message, opts)
    end
  end

  @doc """
  Resolves notification feed IDs to user IDs by querying the Character table.
  This handles the case where notify_feed_ids from live_push are passed instead of user IDs.
  """
  def resolve_feed_ids_to_user_ids(feed_ids) when is_list(feed_ids) do
    from(c in Bonfire.Data.Identity.Character,
      where: c.notifications_id in ^feed_ids,
      select: c.id
    )
    |> repo().many()
  end

  @doc """
  Sends notifications to a list of ExNudge.Subscription structs.
  Handles cleanup of expired subscriptions and tracks status.
  """
  defp send_web_push_to_subscriptions(subscriptions, message, opts \\ [])

  defp send_web_push_to_subscriptions(subscriptions, message, opts)
       when is_list(subscriptions) and subscriptions != [] do
    debug(message, "sending push to #{length(subscriptions)} subscriptions")
    results = ex_nudge_module().send_notifications(subscriptions, message, opts)

    # Update subscription statuses based on results
    Enum.each(results, fn
      {:ok, subscription, _response} ->
        debug(subscription.endpoint, "Push sent to subscription")
        update_subscription_status(subscription, :success)

      {:error, subscription, :subscription_expired} ->
        mark_and_remove_expired(subscription)
        debug(subscription.endpoint, "Removed expired subscription")

      {:error, subscription, reason} ->
        update_subscription_status(subscription, {:error, reason})
        debug(reason, "Failed to send to #{subscription.endpoint}")
    end)

    results
  end

  defp send_web_push_to_subscriptions(subscriptions, _message, _opts) do
    error(subscriptions, "no_subscriptions: No valid subscriptions provided")
    {:error, :no_subscriptions}
  end

  defp update_subscription_status(%ExNudge.Subscription{endpoint: endpoint}, :success) do
    from(s in PushSubscription, where: s.endpoint == ^endpoint)
    |> repo().update_all(
      set: [
        last_status: :success,
        last_used_at: DateTime.utc_now(),
        last_error: nil,
        active: true
      ]
    )
  end

  defp update_subscription_status(%ExNudge.Subscription{endpoint: endpoint}, {:error, reason}) do
    from(s in PushSubscription, where: s.endpoint == ^endpoint)
    |> repo().update_all(
      set: [
        last_status: :error,
        last_used_at: DateTime.utc_now(),
        last_error: inspect(reason)
      ]
    )
  end

  defp mark_and_remove_expired(%ExNudge.Subscription{endpoint: endpoint}) do
    # Delete the push subscription (cascades to user links via on_delete: :delete_all)
    remove_subscription_by_endpoint(endpoint)
  end

  @doc """
  Removes a user's link to a push subscription by its push_subscription_id,
  scoped to the given user.
  """
  def remove_device(user_id, push_subscription_id) do
    case repo().one(
           from(us in UserPushSubscription,
             where: us.id == ^user_id and us.push_subscription_id == ^push_subscription_id
           )
         ) do
      nil -> {:error, :not_found}
      user_sub -> repo().delete(user_sub)
    end
  end

  @doc """
  Removes a subscription by endpoint.
  Deletes the PushSubscription (cascades to UserPushSubscription links).
  """
  def remove_subscription_by_endpoint(endpoint) when is_binary(endpoint) do
    from(s in PushSubscription, where: s.endpoint == ^endpoint)
    |> repo().delete_all()
  end

  @doc """
  Removes a PushSubscription by its database ID.
  """
  def remove_subscription(subscription_id) when is_binary(subscription_id) do
    case repo().get(PushSubscription, subscription_id) do
      nil -> {:error, :subscription_not_found}
      subscription -> repo().delete(subscription)
    end
  end

  @doc """
  Removes a user's link to a push subscription, without deleting the push subscription itself.
  """
  def remove_user_subscription(user_id, push_subscription_id) do
    from(us in UserPushSubscription,
      where: us.id == ^user_id and us.push_subscription_id == ^push_subscription_id
    )
    |> repo().delete_all()
  end

  @doc """
  Deletes all UserPushSubscription links for a given user.
  Does not delete the underlying PushSubscription records.
  """
  def delete_all_for_user(user_id) do
    from(us in UserPushSubscription, where: us.id == ^user_id)
    |> repo().delete_all()
  end

  @doc """
  Gets the most recent active push subscription for a user.
  """
  def get_user_subscription(user_id) do
    from(us in UserPushSubscription,
      join: ps in PushSubscription,
      on: ps.id == us.push_subscription_id,
      where: us.id == ^user_id and ps.active == true,
      order_by: [desc: ps.last_used_at],
      limit: 1,
      preload: [push_subscription: ps]
    )
    |> repo().one()
  end

  @doc """
  Helper to format a push notification message.
  """
  def format_push_message(title, body, opts \\ []) do
    Jason.encode!(%{
      title: title,
      body: body,
      tag: opts[:tag],
      requireInteraction: opts[:require_interaction] || false,
      data: %{url: opts[:url]}
    })
  end

  @doc """
  Broadcasts a message to ALL active subscriptions (admin/testing use).
  Use with caution - this sends to every subscribed user.
  """
  def broadcast(message, opts \\ []) do
    from(us in UserPushSubscription,
      join: ps in PushSubscription,
      on: ps.id == us.push_subscription_id,
      where: ps.active == true,
      select: {us, ps}
    )
    |> repo().all()
    |> Enum.map(fn {user_sub, push_sub} ->
      PushSubscription.to_ex_nudge_subscription(push_sub, user_sub.id)
    end)
    |> send_web_push_to_subscriptions(message, opts)
  end

  @doc """
  Sends a push notification to a single subscription by PushSubscription ID.
  Useful for testing individual subscriptions.
  """
  def send_push_notification(subscription_id, message, opts \\ [])
      when is_binary(subscription_id) do
    case repo().get(PushSubscription, subscription_id) do
      nil ->
        {:error, :subscription_not_found}

      push_sub ->
        push_sub
        |> PushSubscription.to_ex_nudge_subscription()
        |> List.wrap()
        |> send_web_push_to_subscriptions(message, opts)
        |> List.first()
    end
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
