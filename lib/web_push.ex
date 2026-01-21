defmodule Bonfire.Notify.WebPush do
  @moduledoc """
  Manages web push subscriptions and sends notifications using ExNudge.
  """

  use Bonfire.Common.Utils
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.UserSubscription

  @doc """
  Registers a push subscription for a user.
  """
  @spec subscribe(String.t(), map() | String.t()) ::
          {:ok, UserSubscription.t()} | {:error, Ecto.Changeset.t() | atom()}
  def subscribe(user_id, data) when is_binary(data) do
    # Parse JSON string from browser
    case Jason.decode(data) do
      {:ok, parsed_data} -> subscribe(user_id, parsed_data)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def subscribe(user_id, %{} = data) do
    case UserSubscription.parse_subscription_data(data) do
      {:ok, parsed_attrs} ->
        attrs = Map.put(parsed_attrs, :user_id, user_id)

        # Check if subscription already exists by endpoint
        case repo().one(from s in UserSubscription, where: s.endpoint == ^attrs.endpoint) do
          nil ->
            # Insert new subscription
            %UserSubscription{}
            |> UserSubscription.changeset(attrs)
            |> repo().insert()

          existing ->
            # Update existing subscription
            existing
            |> UserSubscription.changeset(attrs)
            |> repo().update()
        end

      {:error, reason} ->
        # Return a changeset error for consistency with insert failures
        {:error,
         %UserSubscription{}
         |> UserSubscription.changeset(%{})
         |> Ecto.Changeset.add_error(:base, to_string(reason))}
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
    list_subscriptions(user_ids)
    |> Enum.group_by(
      & &1.user_id,
      &UserSubscription.to_ex_nudge_subscription/1
    )
  end

  def get_subscriptions(user_id) when is_binary(user_id) do
    get_subscriptions([user_id])
  end

  def list_subscriptions(user_ids) when is_list(user_ids) do
    from(s in UserSubscription,
      where: s.user_id in ^user_ids and s.active == true
    )
    |> repo().many()
  end

  def list_subscriptions(user_id) when is_binary(user_id) do
    list_subscriptions([user_id])
  end

  def list_all_subscriptions(active? \\ true) do
    from(s in UserSubscription, where: s.active == ^active?)
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
        debug(direct_subscriptions, "found subscriptions by user_id")
        direct_subscriptions
      else
        # If no direct matches, try resolving as notification feed IDs
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
    # Query Character table where notifications_id matches any of the feed_ids
    # The character ID is the same as the user ID in Bonfire's Needle schema
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
        # Mark as successful
        update_subscription_status(subscription, :success)

      {:error, subscription, :subscription_expired} ->
        # Mark as expired and remove
        mark_and_remove_expired(subscription)
        debug(subscription.endpoint, "Removed expired subscription")

      {:error, subscription, reason} ->
        # Mark error but keep subscription active
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
    from(s in UserSubscription, where: s.endpoint == ^endpoint)
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
    from(s in UserSubscription, where: s.endpoint == ^endpoint)
    |> repo().update_all(
      set: [
        last_status: :error,
        last_used_at: DateTime.utc_now(),
        last_error: inspect(reason)
      ]
    )
  end

  defp mark_and_remove_expired(%ExNudge.Subscription{endpoint: endpoint}) do
    # Just delete - expired subscriptions are useless
    remove_subscription_by_endpoint(endpoint)
  end

  def remove_device(device_id) do
    entity = repo().get!(UserSubscription, device_id)
    repo().delete(entity)
  end

  @doc """
  Removes a subscription by endpoint.
  """
  def remove_subscription_by_endpoint(endpoint) when is_binary(endpoint) do
    from(s in UserSubscription, where: s.endpoint == ^endpoint)
    |> repo().delete_all()
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
    from(s in UserSubscription, where: s.active == true)
    |> repo().all()
    |> Enum.map(&UserSubscription.to_ex_nudge_subscription/1)
    |> send_web_push_to_subscriptions(message, opts)
  end

  @doc """
  Sends a push notification to a single subscription by database ID.
  Useful for testing individual subscriptions.
  """
  def send_push_notification(subscription_id, message, opts \\ [])
      when is_binary(subscription_id) do
    case repo().get(UserSubscription, subscription_id) do
      nil ->
        {:error, :subscription_not_found}

      subscription ->
        subscription
        |> UserSubscription.to_ex_nudge_subscription()
        |> List.wrap()
        |> send_web_push_to_subscriptions(message, opts)
        |> List.first()
    end
  end

  @doc """
  Removes a subscription by its database ID.
  """
  def remove_subscription(subscription_id) when is_binary(subscription_id) do
    case repo().get(UserSubscription, subscription_id) do
      nil -> {:error, :subscription_not_found}
      subscription -> repo().delete(subscription)
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
