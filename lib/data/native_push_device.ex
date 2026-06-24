defmodule Bonfire.Notify.NativePushDevice do
  @moduledoc """
  Native APNs/FCM device token registered by a Bonfire user.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.NativePushDevice

  @primary_key {:id, :binary_id, autogenerate: true}
  @providers ["apns", "fcm"]
  @policies ["all", "follower", "followed", "none"]
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

  schema "bonfire_notify_native_push_device" do
    field(:user_id, :string)
    field(:provider, :string)
    field(:token, :string)
    field(:token_hash, :string)
    field(:active, :boolean, default: true)
    field(:platform, :string)
    field(:device_name, :string)
    field(:alerts, :map)
    field(:policy, :string)
    field(:last_used_at, :utc_datetime)
    field(:last_status, Ecto.Enum, values: [:success, :error, :expired, :pending])
    field(:last_error, :string)

    timestamps(type: :utc_datetime)
  end

  @doc "Creates or updates a native push device changeset."
  def changeset(struct, attrs, opts \\ []) do
    struct
    |> cast(attrs, [
      :provider,
      :token,
      :active,
      :platform,
      :device_name,
      :alerts,
      :policy,
      :last_used_at,
      :last_status,
      :last_error
    ])
    |> normalize_provider()
    |> put_token_hash()
    |> maybe_put_user_id(opts[:user_id])
    |> validate_required([:user_id, :provider, :token, :token_hash])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:policy, @policies)
    |> validate_inclusion(:last_status, [:success, :error, :expired, :pending])
    |> unique_constraint([:provider, :token_hash])
  end

  @doc "Returns the supported native push providers."
  def providers, do: @providers

  @doc "Returns the default alert preferences."
  def default_alerts, do: @default_alerts

  @doc "Returns effective alerts, resolving nil to defaults."
  def effective_alerts(nil), do: @default_alerts
  def effective_alerts(alerts) when is_map(alerts), do: Map.merge(@default_alerts, alerts)

  @doc "Returns effective policy, resolving nil to all."
  def effective_policy(nil), do: "all"
  def effective_policy(policy), do: policy

  @doc "Hashes a provider device token for lookup and uniqueness."
  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  def get_by_provider_and_token(provider, token) when is_binary(provider) and is_binary(token) do
    provider = String.downcase(provider)
    token_hash = hash_token(token)

    from(d in NativePushDevice, where: d.provider == ^provider and d.token_hash == ^token_hash)
    |> repo().one()
  end

  defp normalize_provider(changeset) do
    case get_change(changeset, :provider) do
      provider when is_binary(provider) ->
        put_change(changeset, :provider, String.downcase(provider))

      _ ->
        changeset
    end
  end

  defp put_token_hash(changeset) do
    case get_field(changeset, :token) do
      token when is_binary(token) and token != "" ->
        put_change(changeset, :token_hash, hash_token(token))

      _ ->
        changeset
    end
  end

  defp maybe_put_user_id(changeset, user_id) when is_binary(user_id),
    do: put_change(changeset, :user_id, user_id)

  defp maybe_put_user_id(changeset, _user_id), do: changeset
end

defmodule Bonfire.Notify.NativePushDevice.Migration do
  @moduledoc false
  use Ecto.Migration

  def migrate_native_push_device(:up) do
    create_if_not_exists table(:bonfire_notify_native_push_device, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, :text, null: false)
      add(:provider, :string, null: false)
      add(:token, :text, null: false)
      add(:token_hash, :string, null: false)
      add(:active, :boolean, default: true, null: false)
      add(:platform, :string)
      add(:device_name, :string)
      add(:alerts, :map)
      add(:policy, :string)
      add(:last_used_at, :utc_datetime)
      add(:last_status, :string)
      add(:last_error, :text)
      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:bonfire_notify_native_push_device, [:user_id]))
    create_if_not_exists(index(:bonfire_notify_native_push_device, [:active]))

    create_if_not_exists(
      unique_index(:bonfire_notify_native_push_device, [:provider, :token_hash])
    )
  end

  def migrate_native_push_device(:down) do
    drop_if_exists(table(:bonfire_notify_native_push_device))
  end
end
