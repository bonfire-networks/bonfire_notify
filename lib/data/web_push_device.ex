defmodule Bonfire.Notify.WebPushDevice do
  @moduledoc """
  The web half of `Bonfire.Notify.PushDevice`: its changeset, its vocabulary, and the shape ExNudge sends to.

  Web devices are rows in the one device table, so there is no schema here. What is here is what web has that native does not: an endpoint URL where native has a device token, and the RFC 8291 encryption keys the browser generated, which the push service never sees and which a native gateway has no counterpart for.

  Two changesets over one schema rather than one branching on `provider`, because each transport can then require exactly what it needs and report errors in its own terms.
  """

  import Untangle
  import Ecto.Changeset

  alias Bonfire.Notify.PushDevice

  @providers [:web, :web_masto]
  @default_provider :web

  @doc """
  The providers this channel delivers to, both of them Web Push endpoints.

  `web` is a client of ours: a browser, an installed PWA, our desktop or mobile app. `web_masto` is a Mastodon client, which is reached in exactly the same way (same endpoint, same encryption, same send) and differs only in the shape of payload it can read, which `Bonfire.Notify.API.MastoPushAdapter` builds. Keeping that as a provider rather than a column of its own means the one thing that can never differ between two people sharing an endpoint is stored once, where the endpoint is.
  """
  def providers, do: @providers

  @doc "What a browser subscribing through our own app is, and the default for anything that doesn't say."
  def provider, do: @default_provider

  @doc """
  A changeset for a Web Push device.

  Nothing here says whose browser it is. Ownership lives on `Bonfire.Notify.UserPushSubscription`, one link per person, which is what lets two accounts logged into one browser both receive their own notifications.
  """
  def changeset(struct \\ %PushDevice{}, attrs) do
    struct
    |> cast(attrs, [:provider, :address, :auth_key, :p256dh_key | PushDevice.shared_cast()])
    |> default_provider()
    |> validate_required([:provider, :address, :auth_key, :p256dh_key])
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint([:provider, :address])
    |> check_constraint(:auth_key, name: :push_device_web_has_keys)
  end

  defp default_provider(changeset) do
    case get_field(changeset, :provider) do
      nil -> put_change(changeset, :provider, @default_provider)
      _ -> changeset
    end
  end

  @doc """
  A Web Push device row by the endpoint its browser knows it as, whichever client registered it.

  Across both providers, because an endpoint is the one thing the browser can tell us about itself and it does not know which of our paths it was registered through.
  """
  def get_by_endpoint(endpoint) when is_binary(endpoint) do
    Enum.find_value(@providers, fn provider -> PushDevice.get_by_address(provider, endpoint) end)
  end

  def get_by_endpoint(_), do: nil

  @doc """
  Finds or creates a Web Push device row by its endpoint, refreshing whatever it sent with it.

  A provider this channel doesn't claim goes straight to the changeset, which is where a caller's mistake belongs: looking it up first would pin an unknown value into a query over an enum column and raise.
  """
  def find_or_create(attrs) do
    case PushDevice.known_provider(attrs[:provider] || @default_provider, @providers) do
      nil -> %PushDevice{} |> changeset(attrs) |> Ecto.Changeset.apply_action(:insert)
      provider -> PushDevice.find_or_create(provider, attrs, &changeset/2)
    end
  end

  @doc """
  Parses browser subscription data into device attrs, plus any link attrs that came with it.

  Accepts both shapes we receive: the browser's own (`endpoint` and `keys`), and the Mastodon API's, which nests that under `subscription` and sends `alerts`/`policy` alongside for the person's link.
  """
  def parse_subscription_data(%{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => p256dh, "auth" => auth}
      }) do
    {:ok, %{address: endpoint, p256dh_key: p256dh, auth_key: auth}}
  end

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
       address: endpoint,
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
  Converts a device row into what ExNudge sends to.

  Takes the recipient's id for the metadata, since a delivery is always on behalf of one person even when the browser is shared.
  """
  def to_ex_nudge_subscription(%PushDevice{} = device, user_id \\ nil) do
    %ExNudge.Subscription{
      endpoint: device.address,
      keys: %{p256dh: device.p256dh_key, auth: device.auth_key},
      metadata: %{id: device.id, user_id: user_id}
    }
  end
end
