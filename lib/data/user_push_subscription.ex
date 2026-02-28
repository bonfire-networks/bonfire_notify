defmodule Bonfire.Notify.UserPushSubscription do
  @moduledoc """
  A multimixin linking a user (Pointer) to a PushSubscription (device endpoint).

  Each row represents one user's relationship to one push endpoint, with
  per-user notification preferences (alerts, policy). Multiple users can
  share the same push endpoint (e.g. a shared browser).

  Similar pattern to `Bonfire.Data.Social.FeedPublish`.
  """

  use Needle.Mixin,
    otp_app: :bonfire_notify,
    source: "bonfire_notify_user_push_subscription"

  require Needle.Changesets
  alias Bonfire.Notify.PushSubscription
  alias Bonfire.Notify.UserPushSubscription
  alias Ecto.Changeset

  mixin_schema do
    belongs_to(:push_subscription, PushSubscription, type: :binary_id, primary_key: true)
    field(:alerts, :map)
    field(:policy, :string)
  end

  @cast [:push_subscription_id, :alerts, :policy]
  @required [:push_subscription_id]

  def changeset(struct \\ %UserPushSubscription{}, params) do
    struct
    |> Changeset.cast(params, @cast)
    |> Changeset.validate_required(@required)
    |> Changeset.validate_inclusion(:policy, ["all", "follower", "followed", "none"])
    |> Changeset.assoc_constraint(:push_subscription)
    |> Changeset.unique_constraint([:id, :push_subscription_id])
  end
end

defmodule Bonfire.Notify.UserPushSubscription.Migration do
  @moduledoc false
  import Ecto.Migration
  import Needle.Migration

  @user_push_sub_table Bonfire.Notify.UserPushSubscription.__schema__(:source)

  defp make_user_push_subscription_table(exprs) do
    quote do
      import Needle.Migration

      Needle.Migration.create_mixin_table Bonfire.Notify.UserPushSubscription do
        Ecto.Migration.add(
          :push_subscription_id,
          references(:bonfire_notify_web_push_subscription,
            type: :binary_id,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false
        )

        Ecto.Migration.add(:alerts, :map)
        Ecto.Migration.add(:policy, :string)

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

  def migrate_user_push_subscription_index(:up, opts),
    do: create_if_not_exists(index(@user_push_sub_table, [:push_subscription_id], opts))

  def migrate_user_push_subscription_index(:down, opts),
    do: drop_if_exists(index(@user_push_sub_table, [:push_subscription_id], opts))

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
