defmodule Bonfire.Notify.UserSubscription do
  @moduledoc """
  The subscription schema for web push notifications.
  """

  use Ecto.Schema
  import Untangle
  import Ecto.Changeset
  import Ecto.Query
  alias Bonfire.Notify.UserSubscription
  import Bonfire.Common.Config, only: [repo: 0]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @default_alerts %{
    "follow" => true,
    "favourite" => true,
    "reblog" => true,
    "mention" => true,
    "poll" => true,
    "status" => false,
    "update" => false
  }

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

    # Mastodon-compatible push subscription fields
    field(:alerts, :map, default: @default_alerts)
    field(:policy, :string, default: "all")
  end

  @doc """
  Creates a changeset for a subscription.

  Note: `user_id` must be set explicitly on the struct before calling changeset,
  or passed as a separate parameter, as it's not included in cast for security.
  """
  def changeset(struct, attrs \\ %{})

  def changeset(struct, attrs) when is_map(attrs) do
    # Set user_id explicitly if provided in attrs (security: not via cast)
    struct =
      case Map.get(attrs, :user_id) || Map.get(attrs, "user_id") do
        nil -> struct
        user_id -> %{struct | user_id: user_id}
      end

    struct
    |> cast(attrs, [
      :endpoint,
      :auth_key,
      :p256dh_key,
      :active,
      :platform,
      :user_agent,
      :device_name,
      :last_used_at,
      :last_status,
      :last_error,
      :alerts,
      :policy
    ])
    |> validate_required([:endpoint, :auth_key, :p256dh_key])
    |> validate_user_id()
    |> validate_inclusion(:last_status, [:success, :error, :expired, :pending])
    |> validate_inclusion(:policy, ["all", "follower", "followed", "none"])
    |> unique_constraint(:endpoint)
  end

  defp validate_user_id(changeset) do
    case Ecto.Changeset.get_field(changeset, :user_id) do
      nil -> add_error(changeset, :user_id, "can't be blank")
      _ -> changeset
    end
  end

  @doc """
  Parses browser subscription data into the format expected by our schema.
  Returns an error tuple if the data structure is invalid.

  Supports both standard browser format and Mastodon API format:
  - Browser: `%{"endpoint" => "...", "keys" => %{"p256dh" => "...", "auth" => "..."}}`
  - Mastodon: `%{"subscription" => %{"endpoint" => "...", "keys" => %{...}}, "data" => %{"alerts" => %{...}, "policy" => "..."}}`
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

  # Mastodon API format: subscription nested under "subscription" key with separate "data" for alerts/policy
  def parse_subscription_data(
        %{
          "subscription" => %{
            "endpoint" => endpoint,
            "keys" => %{"p256dh" => p256dh, "auth" => auth}
          }
        } = params
      ) do
    data = params["data"] || %{}

    {:ok,
     %{
       endpoint: endpoint,
       p256dh_key: p256dh,
       auth_key: auth,
       alerts: data["alerts"] || default_alerts(),
       policy: data["policy"] || "all"
     }}
  end

  def parse_subscription_data(invalid_data) do
    error(invalid_data, "invalid_subscription_data")
    {:error, :invalid_subscription_data}
  end

  @doc """
  Returns the default alerts configuration.
  """
  def default_alerts, do: @default_alerts

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

  def get(user_id) do
    from(s in UserSubscription,
      where: s.user_id == ^user_id and s.active == true,
      order_by: [desc: s.last_used_at],
      limit: 1
    )
    |> repo().one()
  end

  def get_subscription_by_endpoint(endpoint) do
    from(s in UserSubscription, where: s.endpoint == ^endpoint)
    |> repo().one()
  end

  def update_subscription(subscription, attrs) do
    subscription
    |> UserSubscription.changeset(attrs)
    |> repo().update()
  end

  defp maybe_upsert_subscription(nil, attrs, user_id) do
    %UserSubscription{user_id: user_id}
    |> UserSubscription.changeset(attrs)
    |> repo().insert()
  end

  defp maybe_upsert_subscription(existing, attrs, _user_id) do
    update_subscription(existing, attrs)
  end
end
