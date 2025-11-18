defmodule Bonfire.Notify.UserSubscription do
  @moduledoc """
  The subscription schema for web push notifications.
  """

  use Ecto.Schema
  import Untangle
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "bonfire_notify_web_push_subscription" do
    field(:user_id, :binary)
    field(:endpoint, :string)
    field(:auth_key, :string)
    field(:p256dh_key, :string)

    # Tracking fields
    field(:active, :boolean, default: true)
    field(:platform, :string)
    field(:user_agent, :string)
    field(:device_name, :string)
    field(:last_used_at, :utc_datetime)
    field(:last_status, Ecto.Enum, values: [:success, :error, :expired, :pending])
    field(:last_error, :string)
  end

  @doc """
  Creates a changeset for a subscription.
  """
  def changeset(struct, attrs \\ %{}) do
    struct
    |> cast(attrs, [
      :user_id,
      :endpoint,
      :auth_key,
      :p256dh_key,
      :active,
      :platform,
      :user_agent,
      :device_name,
      :last_used_at,
      :last_status,
      :last_error
    ])
    |> validate_required([:user_id, :endpoint, :auth_key, :p256dh_key])
    |> validate_inclusion(:last_status, [:success, :error, :expired, :pending])
    |> unique_constraint(:endpoint)
  end

  @doc """
  Parses browser subscription data into the format expected by our schema.
  Returns an error tuple if the data structure is invalid.
  """
  def parse_subscription_data(%{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => p256dh, "auth" => auth}
      }) do
    {:ok,
     %{
       endpoint: endpoint,
       p256dh_key: p256dh,
       auth_key: auth
     }}
  end

  def parse_subscription_data(invalid_data) do
    error(invalid_data, "invalid_subscription_data")
    {:error, :invalid_subscription_data}
  end

  @doc """
  Converts a UserSubscription record to ExNudge.Subscription format.
  """
  def to_ex_nudge_subscription(%__MODULE__{} = subscription) do
    %ExNudge.Subscription{
      endpoint: subscription.endpoint,
      keys: %{
        p256dh: subscription.p256dh_key,
        auth: subscription.auth_key
      },
      metadata: %{
        id: subscription.id,
        user_id: subscription.user_id
      }
    }
  end

  @doc """
  Updates the last_used_at timestamp for a subscription.
  """
  def touch(subscription) do
    changeset(subscription, %{last_used_at: DateTime.utc_now()})
  end

  @doc """
  Marks a subscription as successful.
  """
  def mark_success(subscription) do
    changeset(subscription, %{
      last_used_at: DateTime.utc_now(),
      last_status: :success,
      last_error: nil,
      active: true
    })
  end

  @doc """
  Marks a subscription as failed with an error.
  """
  def mark_error(subscription, reason) do
    changeset(subscription, %{
      last_used_at: DateTime.utc_now(),
      last_status: :error,
      last_error: inspect(reason)
    })
  end

  @doc """
  Marks a subscription as expired/inactive.
  """
  def mark_expired(subscription) do
    changeset(subscription, %{
      active: false,
      last_status: :expired,
      last_used_at: DateTime.utc_now()
    })
  end
end
