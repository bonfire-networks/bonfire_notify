defmodule Bonfire.Notify.UserSubscriptionsTest do
  use Bonfire.Notify.DataCase, async: true
  use Bonfire.Common.Repo
  import Bonfire.Me.Fake

  alias Bonfire.Data.Identity.User
  alias Bonfire.Notify.PushSubscription
  alias Bonfire.Notify.UserPushSubscription
  alias Bonfire.Notify.UserSubscriptions

  describe "create/2" do
    setup do
      user = fake_user!()
      {:ok, %{user: user}}
    end

    test "inserts the subscription for the user", %{
      user: %User{id: user_id} = user
    } do
      # Create a subscription and verify the user link
      {:ok, user_sub1} = UserSubscriptions.create(user, valid_push_subscription_data("a"))
      assert user_sub1.id == user_id
      assert user_sub1.push_subscription_id

      # Creating with the same endpoint returns the existing link
      {:ok, user_sub2} = UserSubscriptions.create(user, valid_push_subscription_data("a"))
      assert user_sub2.push_subscription_id == user_sub1.push_subscription_id

      # List returns ExNudge.Subscription format
      subscriptions = UserSubscriptions.list(user_id)
      assert %{^user_id => [%ExNudge.Subscription{endpoint: "a"}]} = subscriptions

      # A user can have multiple distinct subscriptions (different endpoints)
      {:ok, _} = UserSubscriptions.create(user, valid_push_subscription_data("b"))

      data =
        [user.id]
        |> UserSubscriptions.list()
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn sub -> sub.endpoint end)
        |> Enum.sort()

      assert data == ["a", "b"]

      # Multiple users can share the same push endpoint
      %User{id: another_user_id} = another_user = fake_user!()

      {:ok, _} =
        UserSubscriptions.create(
          another_user,
          valid_push_subscription_data("a")
        )

      assert %{^another_user_id => [%ExNudge.Subscription{endpoint: "a"}]} =
               UserSubscriptions.list([another_user_id])
    end

    test "returns an error if JSON payload is invalid", %{user: user} do
      assert {:error, :invalid_json} = UserSubscriptions.create(user, "{invalid")
      assert %{} = UserSubscriptions.list([user.id])
    end

    test "returns a changeset error if payload has wrong structure", %{
      user: user
    } do
      assert {:error, %Ecto.Changeset{}} = UserSubscriptions.create(user, %{"foo" => "bar"})
      assert %{} = UserSubscriptions.list([user.id])
    end

    test "updates push subscription keys on duplicate endpoint", %{user: user} do
      {:ok, user_sub1} = UserSubscriptions.create(user, valid_push_subscription_data("endpoint1"))
      original_push_sub_id = user_sub1.push_subscription_id

      # Update with new keys for same endpoint
      data = valid_push_subscription_map("endpoint1")
      data = put_in(data, ["keys", "auth"], "new_auth_key")

      {:ok, user_sub2} = UserSubscriptions.create(user, data)

      # Same push subscription (same endpoint), same user link
      assert user_sub2.push_subscription_id == original_push_sub_id

      # The PushSubscription's keys should be updated
      push_sub = repo().get!(PushSubscription, original_push_sub_id)
      assert push_sub.auth_key == "new_auth_key"
    end
  end

  describe "list/1" do
    test "returns empty map for user with no subscriptions" do
      user = fake_user!()
      assert %{} = UserSubscriptions.list(user.id)
    end

    test "only returns active subscriptions" do
      user = fake_user!()
      {:ok, user_sub} = UserSubscriptions.create(user, valid_push_subscription_data("active"))

      # Mark the PushSubscription as inactive
      push_sub = repo().get!(PushSubscription, user_sub.push_subscription_id)

      push_sub
      |> PushSubscription.mark_expired()
      |> repo().update!()

      # Should not appear in list (filtered by active on PushSubscription)
      assert %{} = UserSubscriptions.list(user.id)
    end

    test "groups subscriptions by user_id" do
      user1 = fake_user!()
      user2 = fake_user!()

      {:ok, _} = UserSubscriptions.create(user1, valid_push_subscription_data("user1_sub1"))
      {:ok, _} = UserSubscriptions.create(user1, valid_push_subscription_data("user1_sub2"))
      {:ok, _} = UserSubscriptions.create(user2, valid_push_subscription_data("user2_sub1"))

      result = UserSubscriptions.list([user1.id, user2.id])

      assert map_size(result) == 2
      assert length(result[user1.id]) == 2
      assert length(result[user2.id]) == 1
    end
  end

  describe "remove_by_endpoint/1" do
    test "removes subscription by endpoint" do
      user = fake_user!()
      {:ok, _} = UserSubscriptions.create(user, valid_push_subscription_data("to_remove"))

      assert %{} != UserSubscriptions.list(user.id)

      UserSubscriptions.remove_by_endpoint("to_remove")

      assert %{} = UserSubscriptions.list(user.id)
    end
  end
end
