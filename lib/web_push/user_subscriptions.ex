defmodule Bonfire.Notify.UserSubscriptions do

  alias Bonfire.Notify.WebPush

  alias Bonfire.Data.Identity.User

  @doc """
  Inserts a push subscription
  """
  @spec create(User.t(), String.t()) ::
          {:ok, WebPush.Subscription.t()} | {:error, atom()}
  def create(%User{id: user_id}, data), do: create(user_id, data)

  def create(user_id, data) do
    case WebPush.subscribe(user_id, data) do
      {:ok, %{subscription: subscription}} -> {:ok, subscription}
      err -> err
    end
  end

  @doc """
  Fetches all push subscriptions for the given user ids.
  """
  @spec list([String.t()]) :: %{
          optional(String.t()) => [WebPush.Subscription.t()]
        }
  def list(user_ids) when is_list(user_ids) do
    WebPush.get_subscriptions(user_ids)
  end

  def list(user_id) do
    list([user_id])
  end

end
