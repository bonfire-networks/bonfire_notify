if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Notify.API.GraphQL do
    @moduledoc "Push notification GraphQL fields and mutations."

    use Absinthe.Schema.Notation
    use Bonfire.Common.Utils

    alias Bonfire.API.GraphQL
    alias Bonfire.Notify.NativePush
    alias Bonfire.Notify.NativePushDevice

    object :native_push_alerts do
      field :follow, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "follow") end)
      end

      field :follow_request, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "follow_request") end)
      end

      field :favourite, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "favourite") end)
      end

      field :reblog, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "reblog") end)
      end

      field :mention, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "mention") end)
      end

      field :poll, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "poll") end)
      end

      field :status, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "status") end)
      end

      field :update, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "update") end)
      end

      field :admin_sign_up, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "admin.sign_up") end)
      end

      field :admin_report, :boolean do
        resolve(fn alerts, _args, _info -> alert(alerts, "admin.report") end)
      end
    end

    input_object :native_push_alerts_input do
      field(:follow, :boolean)
      field(:follow_request, :boolean)
      field(:favourite, :boolean)
      field(:reblog, :boolean)
      field(:mention, :boolean)
      field(:poll, :boolean)
      field(:status, :boolean)
      field(:update, :boolean)
      field(:admin_sign_up, :boolean)
      field(:admin_report, :boolean)
    end

    input_object :native_push_device_input do
      field(:provider, non_null(:string))
      field(:token, non_null(:string))
      field(:platform, :string)
      field(:device_name, :string)
      field(:alerts, :native_push_alerts_input)
      field(:policy, :string)
    end

    object :native_push_device do
      field(:id, :id)
      field(:provider, :string)
      field(:active, :boolean)
      field(:platform, :string)
      field(:device_name, :string)

      field(:policy, :string) do
        resolve(fn device, _args, _info ->
          {:ok, NativePushDevice.effective_policy(device.policy)}
        end)
      end

      field :alerts, :native_push_alerts do
        resolve(fn device, _args, _info ->
          {:ok, NativePushDevice.effective_alerts(device.alerts)}
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
               {:ok, _device} <- NativePush.remove_device(user, device_id) do
            {:ok, true}
          else
            {:error, :not_found} -> {:error, :not_found}
            {:error, reason} -> {:error, reason}
          end
        end)
      end
    end

    defp alert(alerts, key), do: {:ok, Map.get(alerts || %{}, key)}

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
