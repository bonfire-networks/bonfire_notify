defmodule Bonfire.Notify.PushDevice do
  @moduledoc """
  One device we can reach, whatever the transport.

  A device, not a subscription: a subscription is a person's relationship to a device, which is `Bonfire.Notify.UserPushSubscription`. Keeping the two apart is what lets a browser or a phone be shared, with a link per account, and it is why registering a device cannot take it away from whoever registered it first.

  Two transports live here, and `provider` says which, at the grain of "what is listening": `web` and `web_masto` are Web Push endpoints, `apns` and `fcm` are the native gateways. Only one field in each transport's addressing was ever the address, so there is one `address` (a push endpoint URL, or a device token) under one unique index. `auth_key` and `p256dh_key` are RFC 8291 encryption material and belong to the Web Push providers alone, which a check constraint enforces: APNs and FCM carry the payload to themselves in the clear.

  What each transport needs on top of this lives with that transport, in `Bonfire.Notify.WebPushDevice` and `Bonfire.Notify.NativePushDevice`: a changeset asking for the fields it actually requires, and its own vocabulary. Everything both of them do is here.

  Whether a device still works (`active`, `last_status`, `last_used_at`, `last_error`) is written by whichever channel last tried to reach it, which is what lets the settings UI say a device stopped working rather than showing a dead one as healthy.
  """

  use Ecto.Schema
  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription

  @primary_key {:id, :binary_id, autogenerate: true}

  # the bare platform tokens a client may send in place of a User-Agent header. No real User-Agent equals one of these exactly, so the two shapes are unambiguous
  @platforms ~w(ios android windows macos linux)

  schema "bonfire_notify_push_device" do
    # how to reach it, and whose client is listening. A closed set, so an enum: a provider no channel claims is a row nothing could ever deliver to. Each channel owns its own set (`Bonfire.Notify.WebPushDevice.providers/0`, `Bonfire.Notify.NativePushDevice.providers/0`), which is how `web_masto` sits beside `web`: both are Web Push endpoints, encrypted and sent identically, and they differ only in the shape of payload the client at the other end can read
    field(:provider, Ecto.Enum, values: [:web, :web_masto, :apns, :fcm])
    field(:address, :string)

    # RFC 8291 encryption material, web rows only, held there by a check constraint
    field(:auth_key, :string)
    field(:p256dh_key, :string)

    # what the client said it is: its User-Agent header, or its declared platform when it sent none. Parsed for display by `platform/1`, never for a decision
    field(:device_agent, :string)
    field(:device_name, :string)

    # whether it still works
    field(:active, :boolean, default: true)
    field(:last_used_at, :utc_datetime)
    field(:last_status, Ecto.Enum, values: [:success, :error, :expired, :pending])
    field(:last_error, :string)

    has_many(:user_push_subscriptions, UserPushSubscription, foreign_key: :push_device_id)
  end

  @doc """
  The fields every transport writes, for either transport's changeset to cast.

  `provider`, the address and the encryption keys are left out: each transport knows its own gateway, builds its address from what its clients send, and either has keys or must not have them.
  """
  def shared_cast,
    do: [:active, :device_agent, :device_name, :last_used_at, :last_status, :last_error]

  @doc """
  What platform a device is, as far as we can tell, for display only.

  Reads `device_agent`, which holds either a User-Agent header or the client's own word for its platform. A better parser here improves every existing row, which a guess stored at subscribe time could not.

  Nothing decides anything on this: what varies by device is the transport, and an iPhone running our PWA (web push) and one running the native app (APNs) differ by `provider`, not by a platform label.

      iex> Bonfire.Notify.PushDevice.platform("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)")
      "ios"

      iex> Bonfire.Notify.PushDevice.platform("ios")
      "ios"

      iex> Bonfire.Notify.PushDevice.platform("Mozilla/5.0 (X11; Linux x86_64)")
      "linux"

      iex> Bonfire.Notify.PushDevice.platform(nil)
      nil
  """
  def platform(%PushDevice{device_agent: device_agent}), do: platform(device_agent)

  def platform(device_agent) when is_binary(device_agent) do
    cond do
      device_agent in @platforms -> device_agent
      String.contains?(device_agent, "Android") -> "android"
      String.contains?(device_agent, "iPhone") or String.contains?(device_agent, "iPad") -> "ios"
      String.contains?(device_agent, "Windows") -> "windows"
      String.contains?(device_agent, "Mac") -> "macos"
      String.contains?(device_agent, "Linux") -> "linux"
      # a browser we can't place
      true -> "web"
    end
  end

  def platform(_), do: nil

  @doc """
  What to call a device in a list of someone's devices.

  What the client called itself wins, since a person who named their phone "Work iPhone" has said the most useful thing anyone can say about it. Failing that, what can be worked out: which browser issued a Web Push endpoint, or which platform a native client declared. Failing both, the transport, which is at least true.

      iex> Bonfire.Notify.PushDevice.label(%Bonfire.Notify.PushDevice{device_name: "Work iPhone"})
      "Work iPhone"

      iex> Bonfire.Notify.PushDevice.label(%Bonfire.Notify.PushDevice{provider: :web, address: "https://push.apple.com/abc"})
      "Safari or iOS"

      iex> Bonfire.Notify.PushDevice.label(%Bonfire.Notify.PushDevice{provider: :web, address: "https://push.example.test/abc"})
      "Browser"

      iex> Bonfire.Notify.PushDevice.label(%Bonfire.Notify.PushDevice{provider: :apns, device_agent: "ios"})
      "ios"
  """
  def label(%PushDevice{device_name: name}) when is_binary(name) and name != "", do: name

  def label(%PushDevice{provider: provider} = device) do
    if provider in [:web, :web_masto],
      do: client_hint(device),
      else: platform(device) || to_string(provider)
  end

  @doc """
  A guess at what kind of client a Web Push endpoint belongs to, for display only.

  What the endpoint's host actually identifies is the **push service** that issued it, and what that implies about the client is approximate, because a service spans browsers and platforms: Google's FCM serves Chrome on any operating system as well as Android apps, and Apple's serves Safari and iOS. Hence "Chrome or Android" rather than a claim to know which, and hence a hint rather than an answer. Where a device said what it is (`device_name`, `device_agent`) that is better evidence and `label/1` prefers it.

  Beside `platform/1` rather than in the panel that shows it, since reading a stored row is the same job wherever it is rendered, and the settings page, the preferences panel and the API would otherwise each have their own guess.

      iex> Bonfire.Notify.PushDevice.client_hint("https://fcm.googleapis.com/fcm/send/abc")
      "Chrome or Android"

      iex> Bonfire.Notify.PushDevice.client_hint("https://updates.push.services.mozilla.com/wpush/v2/abc")
      "Firefox"

      iex> Bonfire.Notify.PushDevice.client_hint(nil)
      "Browser"
  """
  def client_hint(%PushDevice{address: address}), do: client_hint(address)

  def client_hint(endpoint) when is_binary(endpoint) do
    Enum.find_value(push_service_hints(), "Browser", fn {host, hint} ->
      if String.contains?(endpoint, host), do: hint
    end)
  end

  def client_hint(_), do: "Browser"

  defp push_service_hints do
    Config.get(
      [__MODULE__, :push_service_hints],
      [
        {"fcm.googleapis.com", "Chrome or Android"},
        {"push.apple.com", "Safari or iOS"},
        {"mozilla.com", "Firefox"},
        {"notify.windows.com", "Edge"}
      ],
      name: l("What each push service suggests about a device"),
      description:
        l(
          "Which kind of client each push service's endpoints usually belong to, shown when a device has not said what it is."
        )
    )
  end

  @doc """
  Records what happened to a device: delivered, gone, or failed.

  One copy for every transport, since after the merge there is one row shape to write to. A device the push service says is gone is deactivated rather than deleted, so the row survives long enough for the settings UI to explain why it stopped working, and a prune can clear it later.
  """
  def mark_status(%PushDevice{id: id}, outcome) do
    from(d in PushDevice, where: d.id == ^id)
    |> repo().update_all(set: status_changes(outcome))
  end

  defp status_changes(:success),
    do: [last_status: :success, last_used_at: now(), last_error: nil, active: true]

  defp status_changes({:expired, reason}),
    do: [last_status: :expired, last_used_at: now(), last_error: inspect(reason), active: false]

  defp status_changes({:error, reason}),
    do: [last_status: :error, last_used_at: now(), last_error: inspect(reason)]

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Resolves whatever a client called its provider to one of the ones a channel claims, or nil.

  Anything that queries on `provider` needs this first, since an unknown value pinned into a query over an enum column raises rather than finding nothing, and a client's typo deserves a changeset error instead. Each channel passes its own list, so neither can accidentally claim the other's rows.
  """
  def known_provider(provider, allowed) when is_atom(provider) and not is_nil(provider),
    do: if(provider in allowed, do: provider)

  def known_provider(provider, allowed) when is_binary(provider),
    do: Enum.find(allowed, &(to_string(&1) == provider))

  def known_provider(_provider, _allowed), do: nil

  @doc """
  Finds a device by its address, within its transport.

  Takes the transport as one of the enum's atoms, not as whatever a client sent: an unknown provider pinned into the query would raise, where a client's typo deserves a changeset error. Each transport module resolves its own names before asking.
  """
  def get_by_address(provider, address)
      when is_atom(provider) and not is_nil(provider) and is_binary(address) do
    from(d in PushDevice, where: d.provider == ^provider and d.address == ^address)
    |> repo().one()
  end

  def get_by_address(_provider, _address), do: nil

  @doc """
  Finds or creates a device by address, through the given transport's changeset.

  Finding rather than always inserting is what keeps a shared device one row: two accounts registering the same browser or the same phone get one row here and a link each. Re-running the changeset over the row that was found is what picks up a rotated key or a renamed device.
  """
  def find_or_create(provider, attrs, changeset_fun)
      when is_atom(provider) and is_function(changeset_fun, 2) do
    case get_by_address(provider, attrs[:address]) do
      nil -> changeset_fun.(%PushDevice{}, attrs) |> repo().insert()
      existing -> changeset_fun.(existing, attrs) |> repo().update()
    end
  end
end

defmodule Bonfire.Notify.PushDevice.Migration do
  @moduledoc false
  use Ecto.Migration

  @table "bonfire_notify_push_device"

  @web_keys_constraint "push_device_web_has_keys"

  # the Web Push providers, spelled for SQL from the one list that defines them, so the constraint cannot drift from what the channel claims
  @web_providers Enum.map_join(Bonfire.Notify.WebPushDevice.providers(), ", ", &"'#{&1}'")

  # a Web Push row carries RFC 8291 encryption material and a native row has no counterpart for it, which is the one subtype rule left after the merge. A constraint makes it unfalsifiable, where changeset rules would only hold for writes that go through them
  @web_keys_check "(provider IN (#{@web_providers}) AND auth_key IS NOT NULL AND p256dh_key IS NOT NULL) OR (provider NOT IN (#{@web_providers}) AND auth_key IS NULL AND p256dh_key IS NULL)"

  def table, do: @table

  def migrate_push_device(:up) do
    create_if_not_exists table(@table, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:provider, :string, null: false)
      add(:address, :text, null: false)
      add(:auth_key, :text)
      add(:p256dh_key, :text)
      add(:device_agent, :text)
      add(:device_name, :string)
      add(:active, :boolean, default: true, null: false)
      add(:last_used_at, :utc_datetime)
      add(:last_status, :string)
      add(:last_error, :text)
    end

    create_if_not_exists(unique_index(@table, [:provider, :address]))
    create_if_not_exists(index(@table, [:active]))

    add_web_keys_constraint()
  end

  def migrate_push_device(:down) do
    drop_if_exists(table(@table))
  end

  @doc """
  Adds the web-keys check constraint, defined in one place so a fresh install and the migration that merges the old tables get the same rule.

  Dropped first so running it again is harmless, and so a later change to the rule replaces the old one rather than failing on its name.
  """
  def add_web_keys_constraint do
    execute("ALTER TABLE #{@table} DROP CONSTRAINT IF EXISTS #{@web_keys_constraint}")

    execute(
      "ALTER TABLE #{@table} ADD CONSTRAINT #{@web_keys_constraint} CHECK (#{@web_keys_check})"
    )
  end
end
