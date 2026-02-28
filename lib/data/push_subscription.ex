defmodule Bonfire.Notify.PushSubscription do
  @moduledoc """
  Schema for a browser push subscription endpoint (device-level).

  This represents the browser's push service registration — one per
  service-worker origin + browser + device. Keys (p256dh, auth) are
  tied to the subscription itself, not to any particular user.

  Users are linked via `Bonfire.Notify.UserPushSubscription` (a Needle mixin),
  allowing multiple users to share the same endpoint.
  """

  use Ecto.Schema
  import Untangle
  import Ecto.Changeset
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.PushSubscription

  @primary_key {:id, :binary_id, autogenerate: true}

  @default_alerts %{
    "follow" => true,
    "follow_request" => true,
    "favourite" => true,
    "reblog" => true,
    "mention" => true,
    "poll" => true,
    "status" => false,
    "update" => false,
    "admin.sign_up" => false,
    "admin.report" => false
  }

  schema "bonfire_notify_web_push_subscription" do
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
  Creates a changeset for a push subscription.
  """
  def changeset(struct \\ %PushSubscription{}, attrs) do
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
      :last_error
    ])
    |> validate_required([:endpoint, :auth_key, :p256dh_key])
    |> validate_inclusion(:last_status, [:success, :error, :expired, :pending])
    |> unique_constraint(:endpoint)
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
       alerts: data["alerts"],
       policy: data["policy"]
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
  Returns effective alerts, resolving nil to defaults.
  """
  def effective_alerts(nil), do: @default_alerts
  def effective_alerts(alerts) when is_map(alerts), do: Map.merge(@default_alerts, alerts)

  @doc """
  Returns effective policy, resolving nil to "all".
  """
  def effective_policy(nil), do: "all"
  def effective_policy(policy), do: policy

  @doc """
  Converts a PushSubscription record to ExNudge.Subscription format.

  Optionally accepts a user_id for metadata.
  """
  def to_ex_nudge_subscription(%__MODULE__{} = subscription, user_id \\ nil) do
    %ExNudge.Subscription{
      endpoint: subscription.endpoint,
      keys: %{
        p256dh: subscription.p256dh_key,
        auth: subscription.auth_key
      },
      metadata: %{
        id: subscription.id,
        user_id: user_id
      }
    }
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

  @doc """
  Finds a push subscription by endpoint.
  """
  def get_by_endpoint(endpoint) do
    from(s in PushSubscription, where: s.endpoint == ^endpoint)
    |> repo().one()
  end

  @doc """
  Finds or creates a push subscription by endpoint, updating keys if changed.
  """
  def find_or_create_by_endpoint(attrs) do
    case get_by_endpoint(attrs.endpoint) do
      nil ->
        %PushSubscription{}
        |> changeset(attrs)
        |> repo().insert()

      existing ->
        # Update keys if they changed
        existing
        |> changeset(
          Map.take(attrs, [:auth_key, :p256dh_key, :platform, :user_agent, :device_name])
        )
        |> repo().update()
    end
  end
end
