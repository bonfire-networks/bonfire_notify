defmodule Bonfire.Notifications.UsersTest do
  use Bonfire.Notifications.DataCase, async: true

  alias Bonfire.Notifications.Schemas.User
  alias Bonfire.Notifications.Users
  alias Bonfire.Notifications.WebPush.Subscription

  describe "create_push_subscription/2" do
    setup do
      user = fake_user!()
      {:ok, %{user: user}}
    end

    test "inserts the subscription for the user", %{user: %User{id: user_id} = user} do
      # Gracefully handle duplicates
      {:ok, _} = Users.create_push_subscription(user, valid_push_subscription_data("a"))
      {:ok, _} = Users.create_push_subscription(user, valid_push_subscription_data("a"))

      assert %{^user_id => [%Subscription{endpoint: "a"}]} =
               Users.get_push_subscriptions([user_id])

      # A user can have multiple distinct subscriptions
      {:ok, _} = Users.create_push_subscription(user, valid_push_subscription_data("b"))

      data =
        [user.id]
        |> Users.get_push_subscriptions()
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn sub -> sub.endpoint end)
        |> Enum.sort()

      assert data == ["a", "b"]

      # Multiple users can have the same subscription
      {:ok, %User{id: another_user_id} = another_user} = create_user()
      {:ok, _} = Users.create_push_subscription(another_user, valid_push_subscription_data("a"))

      assert %{^another_user_id => [%Subscription{endpoint: "a"}]} =
               Users.get_push_subscriptions([another_user_id])
    end

    test "returns a parse error if payload is invalid", %{user: user} do
      assert {:error, :parse_error} = Users.create_push_subscription(user, "{")
      assert %{} = Users.get_push_subscriptions([user.id])
    end

    test "returns an invalid keys error if payload has wrong data", %{user: user} do
      assert {:error, :invalid_keys} = Users.create_push_subscription(user, ~s({"foo": "bar"}))
      assert %{} = Users.get_push_subscriptions([user.id])
    end
  end
end
