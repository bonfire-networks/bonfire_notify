defmodule Bonfire.Notify.UserPushSubscription do
  @moduledoc """
  One person's subscription to one device: a multimixin linking a user (Pointer) to a `Bonfire.Notify.PushDevice`.

  This is where ownership and preferences live, which is what lets several people share a device (a browser two accounts are logged into, a phone someone switches personas on) without any of them taking it from the others. A row carries that person's own `alerts`/`policy` for that device, and `access_token_id` when a Mastodon client created it.

  Same pattern as `Bonfire.Data.Social.FeedPublish`.
  """

  use Needle.Mixin,
    otp_app: :bonfire_notify,
    source: "bonfire_notify_user_push_subscription"

  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  require Needle.Changesets
  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription
  alias Ecto.Changeset

  @policies ["all", "follower", "followed", "none"]

  mixin_schema do
    belongs_to(:push_device, PushDevice, type: :binary_id, primary_key: true)
    field(:alerts, :map)
    field(:policy, :string)

    # which OAuth authorisation created this, when a Mastodon client did, since its payload has to carry the token so the client can fetch what it is being told about. Here rather than on the device because a token belongs to one person while the device is shared. What *shape* that payload takes is the device's `provider`, since an endpoint is only ever read by the client software that registered it. A Boruta id, so `Ecto.UUID` rather than a pointer
    field(:access_token_id, Ecto.UUID)
  end

  @cast [:push_device_id, :alerts, :policy, :access_token_id]
  @required [:push_device_id]

  def changeset(struct \\ %UserPushSubscription{}, params) do
    struct
    |> Changeset.cast(params, @cast)
    |> Changeset.validate_required(@required)
    |> Changeset.validate_inclusion(:policy, @policies)
    |> Changeset.assoc_constraint(:push_device)
    |> Changeset.unique_constraint([:id, :push_device_id])
    |> Changeset.unique_constraint(:access_token_id)
  end

  @doc "The audience rules a subscription can carry, which are Mastodon's."
  def policies, do: @policies

  @doc """
  What audience rule applies, resolving an unset one.

  Nobody having chosen reads as `all`, which is what Mastodon's API documents as its default.
  """
  def effective_policy(nil), do: "all"
  def effective_policy(policy), do: policy

  @doc """
  Subscribes a user to a device, or updates what they have already said about it.

  Never touches that person's *other* subscriptions, and never anyone else's to the same device: subscribing on one device leaves the rest alone, which is both the Mastodon push API's rule and what makes a shared device safe.
  """
  def upsert(user_id, push_device_id, attrs \\ %{}) do
    case find(user_id, push_device_id) do
      nil ->
        %UserPushSubscription{id: user_id}
        |> changeset(Map.put(attrs, :push_device_id, push_device_id))
        |> repo().insert()

      existing when attrs == %{} ->
        {:ok, existing}

      existing ->
        existing
        |> changeset(attrs)
        |> repo().update()
    end
  end

  @doc """
  Whether this person could be reached by a push at all, on any device.

  One indexed existence check, for callers that only want the yes or no: whether to offer turning notifications on, or whether there is any point assembling something. Across every transport, since the question is whether anything reaches them rather than which client it is.
  """
  def any_active?(user_id) when is_binary(user_id) do
    from(us in UserPushSubscription,
      join: d in PushDevice,
      on: d.id == us.push_device_id,
      where: us.id == ^user_id and d.active == true
    )
    |> repo().exists?()
  end

  # a user as well as their id, since callers asking this hold the person rather than an id (a getting-started step, a settings panel)
  def any_active?(%{} = user), do: any_active?(id(user))

  def any_active?(_), do: false

  @doc """
  One person's subscription to one device, without its device loaded.

  Named `find` rather than `get`, and `unsubscribe` rather than `delete`, because a schema module here also implements `Access` for its struct: `get/2`, `get/3`, `fetch/2`, `pop/2` and `delete/2` are generated, and a definition of ours under one of those names is quietly replaced rather than rejected. That failure looks like a lookup that finds nothing.
  """
  def find(user_id, push_device_id) do
    from(us in UserPushSubscription,
      where: us.id == ^user_id and us.push_device_id == ^push_device_id
    )
    |> repo().one()
  end

  @doc """
  Unsubscribes a user from a device, leaving the device for anyone else who uses it.
  """
  def unsubscribe(user_id, push_device_id) do
    case find(user_id, push_device_id) do
      nil -> {:error, :not_found}
      link -> repo().delete(link)
    end
  end

  @doc """
  Drops whatever subscription an OAuth authorisation had, leaving the device alone.

  Mastodon's contract is one push subscription per access token, and its POST replaces rather than adds, so a client subscribing a second device with the same token means "reach me here instead". Without this the unique index on the token would turn that legal call into an error.
  """
  def unsubscribe_by_access_token(access_token_id) when is_binary(access_token_id) do
    from(us in UserPushSubscription, where: us.access_token_id == ^access_token_id)
    |> repo().delete_all()
  end

  def unsubscribe_by_access_token(_), do: {0, nil}

  @doc """
  Unsubscribes a user from every device, leaving the devices themselves alone.
  """
  def unsubscribe_all(user_id) do
    from(us in UserPushSubscription, where: us.id == ^user_id)
    |> repo().delete_all()
  end
end

defmodule Bonfire.Notify.UserPushSubscription.Migration do
  @moduledoc false
  import Ecto.Migration
  import Needle.Migration

  @user_push_sub_table Bonfire.Notify.UserPushSubscription.__schema__(:source)

  @access_token_index "bonfire_notify_user_push_subscription_access_token_id_index"

  defp make_user_push_subscription_table(exprs) do
    quote do
      import Needle.Migration

      Needle.Migration.create_mixin_table Bonfire.Notify.UserPushSubscription do
        Ecto.Migration.add(
          :push_device_id,
          references(:bonfire_notify_push_device,
            type: :binary_id,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false
        )

        Ecto.Migration.add(:alerts, :map)
        Ecto.Migration.add(:policy, :string)
        Ecto.Migration.add(:access_token_id, :uuid)

        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_user_push_subscription_table(), do: make_user_push_subscription_table([])

  defmacro create_user_push_subscription_table(do: {_, _, body}),
    do: make_user_push_subscription_table(body)

  def drop_user_push_subscription_table(),
    do: drop_mixin_table(Bonfire.Notify.UserPushSubscription)

  def migrate_user_push_subscription_index(dir \\ direction(), opts \\ [])

  def migrate_user_push_subscription_index(:up, opts) do
    create_if_not_exists(index(@user_push_sub_table, [:push_device_id], opts))
    migrate_access_token_index(:up)
  end

  def migrate_user_push_subscription_index(:down, opts) do
    migrate_access_token_index(:down)
    drop_if_exists(index(@user_push_sub_table, [:push_device_id], opts))
  end

  @doc """
  Mastodon's contract is one push subscription per access token, so the index makes that true rather than hoped: a client re-subscribing replaces its subscription instead of accumulating them.

  Partial, because every subscription that did not come from a Mastodon client has no token at all, and those must not collide with each other.
  """
  def migrate_access_token_index(:up) do
    create_if_not_exists(
      unique_index(@user_push_sub_table, [:access_token_id],
        where: "access_token_id IS NOT NULL",
        name: @access_token_index
      )
    )
  end

  def migrate_access_token_index(:down) do
    drop_if_exists(
      unique_index(@user_push_sub_table, [:access_token_id], name: @access_token_index)
    )
  end

  defp mf(:up) do
    quote do
      Bonfire.Notify.UserPushSubscription.Migration.create_user_push_subscription_table()
      Bonfire.Notify.UserPushSubscription.Migration.migrate_user_push_subscription_index()
    end
  end

  defp mf(:down) do
    quote do
      Bonfire.Notify.UserPushSubscription.Migration.migrate_user_push_subscription_index()
      Bonfire.Notify.UserPushSubscription.Migration.drop_user_push_subscription_table()
    end
  end

  defmacro migrate_user_push_subscription() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(mf(:up)),
        else: unquote(mf(:down))
    end
  end

  defmacro migrate_user_push_subscription(dir), do: mf(dir)
end
