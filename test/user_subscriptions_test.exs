defmodule Bonfire.Notify.UserSubscriptionsTest do
  use Bonfire.Notify.DataCase, async: true

  alias Bonfire.Data.Identity.User
  alias Bonfire.Notify.UserSubscriptions
  alias Bonfire.Notify.WebPush.Subscription

  describe "create/2" do
    setup do
      user = fake_user!()
      {:ok, %{user: user}}
    end

    test "inserts the subscription for the user", %{
      user: %User{id: user_id} = user
    } do
      # Check that we gracefully handle duplicates
      {:ok, _} = UserSubscriptions.create(user, valid_push_subscription_data("a"))

      {:ok, _} = UserSubscriptions.create(user, valid_push_subscription_data("a"))

      assert %{^user_id => [%Subscription{endpoint: "a"}]} = UserSubscriptions.list(user_id)

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

      # Multiple users can have the same subscription
      %User{id: another_user_id} = another_user = fake_user!()

      {:ok, _} =
        UserSubscriptions.create(
          another_user,
          valid_push_subscription_data("a")
        )

      assert %{^another_user_id => [%Subscription{endpoint: "a"}]} =
               UserSubscriptions.list([another_user_id])
    end

    test "returns a parse error if payload is invalid", %{user: user} do
      assert {:error, :parse_error} = UserSubscriptions.create(user, "{")
      assert %{} = UserSubscriptions.list([user.id])
    end

    test "returns an invalid keys error if payload has wrong data", %{
      user: user
    } do
      assert {:error, :invalid_keys} = UserSubscriptions.create(user, ~s({"foo": "bar"}))

      assert %{} = UserSubscriptions.list([user.id])
    end
  end
end
