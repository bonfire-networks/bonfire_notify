defmodule Bonfire.Notify.DataMigrations.FoldNativeDevicesTest do
  use Bonfire.Notify.DataCase, async: false

  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Common.Repo
  alias Bonfire.Notify.DataMigrations.FoldNativeDevices
  alias Bonfire.Notify.NativePush
  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription

  # the table these rows come from is dropped by the migration that runs the fold, so the test makes it again to have something to fold. The sandbox transaction takes it away afterwards
  setup do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{FoldNativeDevices.table()} (
      id uuid PRIMARY KEY,
      user_id text NOT NULL,
      provider varchar(255) NOT NULL,
      token text NOT NULL,
      token_hash varchar(255) NOT NULL,
      active boolean NOT NULL DEFAULT true,
      platform varchar(255),
      device_name varchar(255),
      alerts jsonb,
      policy varchar(255),
      last_used_at timestamp(0),
      last_status varchar(255),
      last_error text,
      inserted_at timestamp(0) NOT NULL DEFAULT now(),
      updated_at timestamp(0) NOT NULL DEFAULT now()
    )
    """)

    :ok
  end

  defp insert_legacy(attrs) do
    id = Ecto.UUID.bingenerate()
    token = attrs[:token] || "legacy-token-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO #{FoldNativeDevices.table()}
        (id, user_id, provider, token, token_hash, active, platform, device_name, policy, last_status)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
      """,
      [
        id,
        attrs.user_id,
        attrs[:provider] || "apns",
        token,
        :crypto.hash(:sha256, token) |> Base.encode16(case: :lower),
        Map.get(attrs, :active, true),
        attrs[:platform],
        attrs[:device_name],
        attrs[:policy],
        attrs[:last_status]
      ]
    )

    %{id: id, token: token}
  end

  defp legacy_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{FoldNativeDevices.table()}")
    count
  end

  defp fold do
    FoldNativeDevices.base_query()
    |> Repo.all()
    |> FoldNativeDevices.migrate()
  end

  defp devices_by_address(address) do
    repo().many(from(d in PushDevice, where: d.address == ^address))
  end

  defp subscriptions_for(device_id) do
    repo().many(from(us in UserPushSubscription, where: us.push_device_id == ^device_id))
  end

  test "a native row becomes a device plus that person's subscription" do
    alice = fake_user!()

    legacy =
      insert_legacy(%{
        user_id: alice.id,
        provider: "fcm",
        platform: "ios",
        device_name: "Alice's phone",
        policy: "follower",
        last_status: "success"
      })

    fold()

    assert [device] = devices_by_address(legacy.token)
    assert device.provider == :fcm
    assert device.address == legacy.token

    # the old column held what the client declared about itself, which is what `device_agent` is for
    assert device.device_agent == "ios"
    assert device.device_name == "Alice's phone"
    assert device.active == true
    assert device.last_status == :success

    # no encryption keys: those are the web transport's, and a check constraint would refuse them here
    assert is_nil(device.auth_key)
    assert is_nil(device.p256dh_key)

    assert [link] = subscriptions_for(device.id)
    assert link.id == alice.id
    assert link.policy == "follower"

    # folded rows are deleted, which is what lets an interrupted run resume instead of starting over
    assert legacy_count() == 0
  end

  test "an inactive device stays inactive, with why it stopped working" do
    alice = fake_user!()
    legacy = insert_legacy(%{user_id: alice.id, active: false, last_status: "expired"})

    fold()

    assert [device] = devices_by_address(legacy.token)
    assert device.active == false
    assert device.last_status == :expired
  end

  test "a device somebody has already registered gains a subscription rather than a twin" do
    alice = fake_user!()
    bob = fake_user!()

    # bob has registered this phone through the merged path already, which is also the shape of a re-run
    assert {:ok, registered} =
             NativePush.register(bob, %{provider: "apns", token: "shared-phone", platform: "ios"})

    insert_legacy(%{user_id: alice.id, provider: "apns", token: "shared-phone"})

    fold()

    assert [device] = devices_by_address("shared-phone")
    assert device.id == registered.push_device_id

    # one device, a subscription each: the old table could only name one owner, which is how registering used to take a phone away from whoever had it first
    assert subscriptions_for(device.id) |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([alice.id, bob.id])

    assert legacy_count() == 0
  end

  test "folding twice leaves one device and one subscription" do
    alice = fake_user!()
    legacy = insert_legacy(%{user_id: alice.id, token: "same-phone"})

    fold()

    # the rows are gone, so a second run has nothing to do, and re-inserting the same row must not duplicate anything either
    insert_legacy(%{user_id: alice.id, token: legacy.token})
    fold()

    assert [device] = devices_by_address(legacy.token)
    assert [_one] = subscriptions_for(device.id)
  end

  test "leaves behind a row whose owner no longer exists" do
    legacy = insert_legacy(%{user_id: Needle.ULID.generate()})

    fold()

    # nobody to subscribe, and the mixin's foreign key would raise rather than refuse, so the batch must not even try
    assert devices_by_address(legacy.token) == []
    assert legacy_count() == 1
  end

  test "folds every row in a batch, and only stops on the ones it cannot" do
    alice = fake_user!()
    bob = fake_user!()

    insert_legacy(%{user_id: alice.id, token: "alice-phone"})
    insert_legacy(%{user_id: bob.id, token: "bob-phone"})
    insert_legacy(%{user_id: Needle.ULID.generate(), token: "ghost-phone"})

    fold()

    assert [_] = devices_by_address("alice-phone")
    assert [_] = devices_by_address("bob-phone")
    assert devices_by_address("ghost-phone") == []
    assert legacy_count() == 1
  end
end
