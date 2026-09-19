if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Notify.API.GraphQL do
    @moduledoc "Push notification GraphQL fields and mutations."

    use Absinthe.Schema.Notation
    use Bonfire.Common.Utils

    alias Bonfire.API.GraphQL
    alias Bonfire.Notify.NativePush
    alias Bonfire.Notify.PushDevice
    alias Bonfire.Notify.UserPushSubscription

    input_object :native_push_device_input do
      field(:provider, non_null(:string))
      field(:token, non_null(:string))
      field(:platform, :string)
      field(:device_name, :string)

      field(:policy, :string,
        description:
          "Pass \"none\" to register a device without pushing to it. What you are notified about is a per-verb, per-channel setting on your user settings, so registering a device says where to reach you and nothing about what to send."
      )
    end

    # one device as one person sees it: the device's own fields, and this person's settings for it. Resolved from their subscription rather than from the device row, because a device can be shared and the settings are never shared with it
    object :native_push_device do
      field(:id, :id, resolve: fn link, _, _ -> {:ok, link.push_device_id} end)

      field(:provider, :string,
        resolve: fn link, _, _ -> {:ok, to_string(link.push_device.provider)} end
      )

      field(:active, :boolean, resolve: fn link, _, _ -> {:ok, link.push_device.active} end)

      field(:device_name, :string,
        resolve: fn link, _, _ -> {:ok, link.push_device.device_name} end
      )

      field(:platform, :string,
        description:
          "What kind of device this looks like, parsed from what the client said about itself. For display: what decides how we reach a device is its provider."
      ) do
        resolve(fn link, _args, _info -> {:ok, PushDevice.platform(link.push_device)} end)
      end

      field(:policy, :string) do
        resolve(fn link, _args, _info ->
          {:ok, UserPushSubscription.effective_policy(link.policy)}
        end)
      end
    end

    object :notify_queries do
      field :my_push_devices, list_of(:native_push_device) do
        resolve(fn _parent, _args, info ->
          with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
            {:ok, NativePush.list_devices(user)}
          end
        end)
      end
    end

    object :notify_mutations do
      field :register_push_device, :native_push_device do
        arg(:input, non_null(:native_push_device_input))

        resolve(fn _parent, %{input: input}, info ->
          with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
            # registering says where to reach someone, not what to send them: what they are notified about is a per-verb, per-channel setting on the account. Only `Bonfire.Notify.API.MastoPushAdapter` stores an alerts map, because only that API's rules need one
            case NativePush.register(user, input) do
              {:ok, device} -> {:ok, device}
              {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
              {:error, reason} -> {:error, reason}
            end
          end
        end)
      end

      field :remove_push_device, :boolean do
        arg(:id, non_null(:id))

        resolve(fn _parent, %{id: device_id}, info ->
          with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
               {:ok, _unsubscribed} <- NativePush.remove_device(user, device_id) do
            {:ok, true}
          else
            {:error, :not_found} -> {:error, :not_found}
            {:error, reason} -> {:error, reason}
          end
        end)
      end
    end

    defp changeset_error(%Ecto.Changeset{} = changeset) do
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
      |> Enum.map(fn {key, values} -> "#{key}: #{Enum.join(values, ", ")}" end)
      |> Enum.join("; ")
    end
  end
end
