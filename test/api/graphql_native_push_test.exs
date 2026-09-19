if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Notify.API.GraphQL.NativePushTest do
    use Bonfire.Notify.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema
    alias Bonfire.Notify.NativePush
    alias Bonfire.Notify.PushDevice
    import Bonfire.Common.Config, only: [repo: 0]

    @moduletag :graphql

    @register """
    mutation($input: NativePushDeviceInput!) {
      register_push_device(input: $input) {
        id
        provider
        platform
        device_name
        policy
        active
      }
    }
    """

    @devices """
    query {
      my_push_devices {
        id
        provider
        platform
        device_name
      }
    }
    """

    setup do
      user = fake_user!()
      {:ok, user: user}
    end

    test "registers and lists native push devices", %{user: user} do
      {:ok, result} =
        Absinthe.run(@register, Schema,
          variables: %{
            "input" => %{
              "provider" => "FCM",
              "token" => "fcm-token-graphql",
              "platform" => "ios",
              "device_name" => "Ivan's iPhone",
              "policy" => "all"
            }
          },
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors]
      device = get_in(result, [:data, "register_push_device"])
      assert is_binary(device["id"])
      assert device["provider"] == "fcm"
      assert device["platform"] == "ios"
      assert device["device_name"] == "Ivan's iPhone"
      assert device["active"] == true

      stored = repo().get!(PushDevice, device["id"])
      assert stored.address == "fcm-token-graphql"

      # the device says nothing about whose it is: one subscription per person does, which is what lets two accounts share a phone
      assert [subscription] = NativePush.list_devices(user)
      assert subscription.id == user.id

      refute subscription.alerts,
             "registering says where to reach someone; what to send them is a setting on their account, and only the Mastodon API's own rules need a per-device map"

      {:ok, list_result} =
        Absinthe.run(@devices, Schema, context: Schema.context(%{current_user: user}))

      refute list_result[:errors]
      assert [%{"id" => id}] = get_in(list_result, [:data, "my_push_devices"])
      assert id == device["id"]
    end

    test "updates an existing native token and removes it", %{user: user} do
      input = %{
        "provider" => "apns",
        "token" => "apns-token-graphql",
        "platform" => "ios",
        "device_name" => "Old phone"
      }

      {:ok, first_result} =
        Absinthe.run(@register, Schema,
          variables: %{"input" => input},
          context: Schema.context(%{current_user: user})
        )

      first_id = get_in(first_result, [:data, "register_push_device", "id"])
      assert is_binary(first_id)

      {:ok, second_result} =
        Absinthe.run(@register, Schema,
          variables: %{"input" => %{input | "device_name" => "New phone"}},
          context: Schema.context(%{current_user: user})
        )

      refute second_result[:errors]
      assert get_in(second_result, [:data, "register_push_device", "id"]) == first_id
      assert get_in(second_result, [:data, "register_push_device", "device_name"]) == "New phone"

      {:ok, remove_result} =
        Absinthe.run(
          "mutation($id: ID!) { remove_push_device(id: $id) }",
          Schema,
          variables: %{"id" => first_id},
          context: Schema.context(%{current_user: user})
        )

      refute remove_result[:errors]
      assert get_in(remove_result, [:data, "remove_push_device"]) == true
    end

    test "requires login" do
      {:ok, result} =
        Absinthe.run(@register, Schema,
          variables: %{
            "input" => %{
              "provider" => "fcm",
              "token" => "no-user-token"
            }
          },
          context: Schema.context(%{})
        )

      assert result[:errors]
      assert get_in(result, [:data, "register_push_device"]) == nil
    end
  end
end
