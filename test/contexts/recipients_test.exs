defmodule Bonfire.Notify.RecipientsTest do
  @moduledoc """
  Loading the people a fan-out job names, and by which of their feeds it reached them.

  The write path resolves its recipients while addressing an activity, so the usual case is a lookup
  by id; feed ids are only carried for the paths that never had people (a circle's notifications, the
  admin feeds), and both are answered by one query. The feed that reached someone is kept because
  `:inbox` means a DM, which is delivered differently, and settings come loaded for the user
  and their account, or an account-scope preference is silently ignored.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E

  alias Bonfire.Notify.Recipients
  alias Bonfire.Social.Feeds

  setup do
    alice = Bonfire.Me.Fake.fake_user!()
    bob = Bonfire.Me.Fake.fake_user!()
    {:ok, alice: alice, bob: bob}
  end

  defp classes(recipients),
    do: recipients |> Enum.map(fn {user, feed} -> {user.id, feed} end) |> Enum.sort()

  test "loads the recipients a job carried, with the feed each was reached by", %{
    alice: alice,
    bob: bob
  } do
    loaded =
      Recipients.for_job([
        %{"user_id" => bob.id, "feed" => "notifications"},
        %{"user_id" => alice.id, "feed" => "inbox"}
      ])

    assert classes(loaded) == Enum.sort([{bob.id, :notifications}, {alice.id, :inbox}])
  end

  test "defaults to notifications when a job doesn't say", %{bob: bob} do
    assert [{_user, :notifications}] = Recipients.for_job([%{"user_id" => bob.id}])
  end

  test "resolves a feed nobody was named for", %{bob: bob} do
    assert [{user, :notifications}] =
             Recipients.for_job([], [Feeds.my_feed_id(:notifications, bob)])

    assert user.id == bob.id
  end

  test "an inbox feed resolves as an inbox, which is how a DM is told apart", %{bob: bob} do
    assert [{user, :inbox}] = Recipients.for_job([], [Feeds.my_feed_id(:inbox, bob)])
    assert user.id == bob.id
  end

  test "named recipients and bare feeds come back together, nobody twice", %{
    alice: alice,
    bob: bob
  } do
    loaded =
      Recipients.for_job(
        [%{"user_id" => bob.id, "feed" => "notifications"}],
        [Feeds.my_feed_id(:notifications, bob), Feeds.my_feed_id(:notifications, alice)]
      )

    assert classes(loaded) == Enum.sort([{bob.id, :notifications}, {alice.id, :notifications}])
  end

  test "what the job states wins over what the feed implies", %{bob: bob} do
    # reached by their notifications feed, but the job says this was a DM
    loaded =
      Recipients.for_job(
        [%{"user_id" => bob.id, "feed" => "inbox"}],
        [Feeds.my_feed_id(:notifications, bob)]
      )

    assert classes(loaded) == [{bob.id, :inbox}]
  end

  test "excludes whoever is named, which is how nobody notifies themselves", %{
    alice: alice,
    bob: bob
  } do
    loaded =
      Recipients.for_job(
        [%{"user_id" => alice.id}, %{"user_id" => bob.id}],
        [],
        exclude: alice
      )

    assert classes(loaded) == [{bob.id, :notifications}]
  end

  test "nothing named and no feeds means nobody, without a query" do
    assert Recipients.for_job([], []) == []
  end

  test "loads the settings that decide delivery, for the user and the account", %{bob: bob} do
    assert [{recipient, _feed}] = Recipients.for_job([%{"user_id" => bob.id}])

    refute match?(%Ecto.Association.NotLoaded{}, recipient.settings)

    assert %Ecto.Association.NotLoaded{} != e(recipient, :accounted, :account, :settings, nil),
           "account settings must be loaded, or an account-scope preference is silently ignored"
  end
end
