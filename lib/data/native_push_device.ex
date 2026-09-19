defmodule Bonfire.Notify.NativePushDevice do
  @moduledoc """
  The native half of `Bonfire.Notify.PushDevice`: its changeset and its vocabulary.

  Native devices are rows in the one device table, so there is no schema here. What is here is what native has that web does not: a gateway to name (`apns` or `fcm`), and a device token where web has an endpoint URL. Clients speak of a `token` and a `platform`, so this module is also where those names meet the shared columns.

  Two changesets over one schema rather than one branching on `provider`, because each transport can then require exactly what it needs and report errors in its own terms.
  """

  import Ecto.Changeset

  alias Bonfire.Notify.PushDevice

  @providers [:apns, :fcm]

  @doc "The native push gateways we can send through."
  def providers, do: @providers

  @doc """
  A changeset for a native push device, in native vocabulary.

  Takes `token` and `platform` as a client sends them: the token is the device's `address`, and a declared platform is its `device_agent`, since a native HTTP client often sends no User-Agent header and then its own word for itself is all there is.

  Nothing here says whose device it is. Ownership lives on `Bonfire.Notify.UserPushSubscription`, one link per person, which is what lets two accounts share a phone instead of taking it from each other.
  """
  def changeset(struct \\ %PushDevice{}, attrs) do
    struct
    |> cast(native_names(attrs), [:provider, :address | PushDevice.shared_cast()])
    # a native gateway carries the payload to itself, so there is nothing to encrypt it with, and the check constraint refuses a native row holding keys anyway
    |> put_change(:auth_key, nil)
    |> put_change(:p256dh_key, nil)
    |> validate_required([:provider, :address])
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint([:provider, :address])
  end

  @doc """
  Finds or creates a device row by its token, within its gateway.

  A second account registering the same phone finds the row rather than taking it over, and gets a link of its own.

  A gateway we don't know goes straight to the changeset, which is where a client's typo belongs: looking it up first would pin an unknown value into a query over an enum column and raise.
  """
  def find_or_create(attrs) do
    attrs = native_names(attrs)

    case PushDevice.known_provider(attrs[:provider], @providers) do
      nil -> %PushDevice{} |> changeset(attrs) |> Ecto.Changeset.apply_action(:insert)
      provider -> PushDevice.find_or_create(provider, attrs, &changeset/2)
    end
  end

  # translating rather than casting these keys, so a client's vocabulary never appears as a column name. Running it twice is harmless, which lets `find_or_create/1` translate before looking the address up and still hand the changeset the same attrs
  defp native_names(attrs) do
    attrs
    |> rename_key(:token, :address)
    |> rename_key(:platform, :device_agent)
  end

  defp rename_key(attrs, from, to) do
    case Map.pop(attrs, from) do
      {nil, attrs} -> attrs
      {value, attrs} -> Map.put(attrs, to, value)
    end
  end
end
