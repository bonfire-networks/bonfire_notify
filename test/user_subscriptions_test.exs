defmodule Bonfire.Notify.UserSubscriptionsTest do
  use Bonfire.Notify.DataCase, async: true
  use Bonfire.Common.Repo
  import Bonfire.Me.Fake

  alias Bonfire.Data.Identity.User
  alias Bonfire.Notify.UserSubscription
  alias Bonfire.Notify.UserSubscriptions

  describe "create/2" do
    setup do
      user = fake_user!()
      {:ok, %{user: user}}
    end

    test "inserts the subscription for the user", %{
      user: %User{id: user_id} = user
    } do
      # Check that we gracefully handle duplicates
      {:ok, sub1} = UserSubscriptions.create(user, valid_push_subscription_data("a"))
      assert sub1.endpoint == "a"
      assert sub1.user_id == user_id

      {:ok, sub2} = UserSubscriptions.create(user, valid_push_subscription_data("a"))
      # Same subscription updated
      assert sub2.id == sub1.id

      # List returns ExNudge.Subscription format
      subscriptions = UserSubscriptions.list(user_id)
      assert %{^user_id => [%ExNudge.Subscription{endpoint: "a"}]} = subscriptions

      # A user can have multiple distinct subscriptions
      {:ok, _} = UserSubscriptions.create(user, valid_push_subscription_data("b"))

      data =
        [user.id]
        |> UserSubscriptions.list()
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn sub -> sub.endpoint end)
        |> Enum.sort()

      assert data == ["a", "b"]

      # Multiple users can have the same subscription endpoint (different devices)
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

    test "updates subscription on duplicate endpoint", %{user: user} do
      {:ok, sub1} = UserSubscriptions.create(user, valid_push_subscription_data("endpoint1"))
      original_id = sub1.id

      # Update with new keys for same endpoint
      data = valid_push_subscription_map("endpoint1")
      data = put_in(data, ["keys", "auth"], "new_auth_key")

      {:ok, sub2} = UserSubscriptions.create(user, data)

      # Should be same subscription ID but with updated keys
      assert sub2.id == original_id
      assert sub2.auth_key == "new_auth_key"
    end
  end

  describe "list/1" do
    test "returns empty map for user with no subscriptions" do
      user = fake_user!()
      assert %{} = UserSubscriptions.list(user.id)
    end

    test "only returns active subscriptions" do
      user = fake_user!()
      {:ok, sub} = UserSubscriptions.create(user, valid_push_subscription_data("active"))

      # Mark as inactive
      sub
      |> UserSubscription.mark_expired()
      |> repo().update!()

      # Should not appear in list
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
