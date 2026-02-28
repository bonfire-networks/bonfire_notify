defmodule Bonfire.Notify.UserSubscriptions do
  @moduledoc """
  Public API for managing user push notification subscriptions.
  """

  alias Bonfire.Notify.WebPush
  alias Bonfire.Data.Identity.User

  @doc """
  Creates a push subscription for a user.
  """
  @spec create(User.t() | String.t(), map() | String.t()) ::
          {:ok, any()} | {:error, atom()}
  def create(%User{id: user_id}, data), do: create(user_id, data)

  def create(user_id, data) when is_binary(user_id) do
    WebPush.subscribe(user_id, data)
  end

  @doc """
  Fetches all push subscriptions for the given user ids.
  Returns ExNudge.Subscription structs ready for sending.
  """
  @spec list([String.t()] | String.t()) :: %{
          optional(String.t()) => [ExNudge.Subscription.t()]
        }
  def list(user_ids) when is_list(user_ids) do
    WebPush.get_subscriptions(user_ids)
  end

  def list(user_id) when is_binary(user_id) do
    WebPush.get_subscriptions([user_id])
  end

  @doc """
  Removes a subscription by endpoint.
  """
  def remove_by_endpoint(endpoint) when is_binary(endpoint) do
    WebPush.remove_subscription_by_endpoint(endpoint)
  end
end
