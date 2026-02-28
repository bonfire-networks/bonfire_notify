defmodule Bonfire.Notify.API.MastoPushAdapter do
  @moduledoc """
  Mastodon-compatible push subscription API adapter.

  Implements the Mastodon push subscription API:
  - POST /api/v1/push/subscription - Create subscription
  - GET /api/v1/push/subscription - Get current subscription
  - PUT /api/v1/push/subscription - Update subscription alerts/policy
  - DELETE /api/v1/push/subscription - Delete subscription
  """

  use Bonfire.Common.Utils
  import Untangle
  import Ecto.Query

  alias Bonfire.API.GraphQL.RestAdapter
  alias Bonfire.Notify.PushSubscription
  alias Bonfire.Notify.UserPushSubscription
  alias Bonfire.Notify.WebPush
  import Bonfire.Common.Config, only: [repo: 0]

  @doc """
  Creates a new push subscription for the current user.

  Expects params in Mastodon format:
  ```
  {
    "subscription": {
      "endpoint": "https://push.example.com/...",
      "keys": {"p256dh": "...", "auth": "..."}
    },
    "data": {
      "alerts": {"mention": true, "reblog": false, ...},
      "policy": "all"
    }
  }
  ```
  """
  def create(params, conn) do
    RestAdapter.with_current_user(conn, fn current_user ->
      case PushSubscription.parse_subscription_data(params) do
        {:ok, parsed_attrs} ->
          user_id = id(current_user)

          # Per Mastodon spec: creating a new subscription replaces the old one
          WebPush.delete_all_for_user(user_id)

          device_attrs =
            parsed_attrs
            |> Map.take([:endpoint, :auth_key, :p256dh_key])
            |> maybe_add_device_info(conn)

          with {:ok, push_sub} <- PushSubscription.find_or_create_by_endpoint(device_attrs) do
            user_attrs =
              Map.take(parsed_attrs, [:alerts, :policy])
              |> Map.put(:push_subscription_id, push_sub.id)

            %UserPushSubscription{id: user_id}
            |> UserPushSubscription.changeset(user_attrs)
            |> repo().insert()
            |> respond_with_subscription(push_sub, conn)
          else
            {:error, reason} ->
              RestAdapter.error_fn({:error, inspect(reason)}, conn)
          end

        {:error, _reason} ->
          RestAdapter.error_fn({:error, "Invalid subscription data"}, conn)
      end
    end)
  end

  @doc """
  Gets the current user's push subscription.

  Returns 404 if no subscription exists.
  """
  def show(conn) do
    RestAdapter.with_current_user(conn, fn current_user ->
      user_id = id(current_user)

      case WebPush.get_user_subscription(user_id) do
        nil ->
          RestAdapter.error_fn({:error, :not_found}, conn)

        user_sub ->
          RestAdapter.json(conn, format_response(user_sub, user_sub.push_subscription))
      end
    end)
  end

  @doc """
  Updates the current user's push subscription alerts and/or policy.

  Does NOT update the endpoint or keys - only alerts/policy can be modified.

  Expects params:
  ```
  {
    "data": {
      "alerts": {"mention": true, "reblog": false, ...},
      "policy": "follower"
    }
  }
  ```
  """
  def update(params, conn) do
    RestAdapter.with_current_user(conn, fn current_user ->
      user_id = id(current_user)

      case WebPush.get_user_subscription(user_id) do
        nil ->
          RestAdapter.error_fn({:error, :not_found}, conn)

        user_sub ->
          data = params["data"] || %{}

          update_attrs =
            %{}
            |> maybe_put_alerts(data["alerts"], user_sub.alerts)
            |> maybe_put_policy(data["policy"])

          case user_sub
               |> UserPushSubscription.changeset(update_attrs)
               |> repo().update() do
            {:ok, updated} ->
              RestAdapter.json(conn, format_response(updated, user_sub.push_subscription))

            {:error, changeset} ->
              RestAdapter.error_fn({:error, changeset_error(changeset)}, conn)
          end
      end
    end)
  end

  @doc """
  Deletes the current user's push subscription.

  Returns empty 200 on success.
  """
  def delete(conn) do
    RestAdapter.with_current_user(conn, fn current_user ->
      user_id = id(current_user)

      # Delete user's links, not the underlying PushSubscription (per Mastodon spec)
      WebPush.delete_all_for_user(user_id)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{}")
    end)
  end

  # Private helpers

  defp respond_with_subscription({:ok, user_sub}, push_sub, conn) do
    RestAdapter.json(conn, format_response(user_sub, push_sub))
  end

  defp respond_with_subscription({:error, changeset}, _push_sub, conn) do
    RestAdapter.error_fn({:error, changeset_error(changeset)}, conn)
  end

  defp maybe_add_device_info(attrs, conn) do
    user_agent = Plug.Conn.get_req_header(conn, "user-agent") |> List.first()

    attrs
    |> Map.put(:user_agent, user_agent)
    |> Map.put(:platform, detect_platform(user_agent))
  end

  defp detect_platform(nil), do: nil

  defp detect_platform(user_agent) do
    cond do
      String.contains?(user_agent, "Android") -> "android"
      String.contains?(user_agent, "iPhone") or String.contains?(user_agent, "iPad") -> "ios"
      String.contains?(user_agent, "Windows") -> "windows"
      String.contains?(user_agent, "Mac") -> "macos"
      String.contains?(user_agent, "Linux") -> "linux"
      true -> "web"
    end
  end

  defp maybe_put_alerts(attrs, nil, _existing), do: attrs

  defp maybe_put_alerts(attrs, new_alerts, existing_alerts) when is_map(new_alerts) do
    merged = Map.merge(PushSubscription.effective_alerts(existing_alerts), new_alerts)
    Map.put(attrs, :alerts, merged)
  end

  defp maybe_put_alerts(attrs, _invalid, _existing), do: attrs

  defp maybe_put_policy(attrs, nil), do: attrs

  defp maybe_put_policy(attrs, policy) when policy in ["all", "follower", "followed", "none"] do
    Map.put(attrs, :policy, policy)
  end

  defp maybe_put_policy(attrs, _invalid), do: attrs

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end

  defp changeset_error(other), do: inspect(other)

  @doc """
  Formats a subscription into Mastodon API response format.
  """
  def format_response(%UserPushSubscription{} = user_sub, %PushSubscription{} = push_sub) do
    %{
      "id" => push_sub.id,
      "endpoint" => push_sub.endpoint,
      "standard" => false,
      "server_key" => vapid_public_key(),
      "alerts" => PushSubscription.effective_alerts(user_sub.alerts),
      "policy" => PushSubscription.effective_policy(user_sub.policy)
    }
  end

  defp vapid_public_key do
    Application.get_env(:ex_nudge, :vapid_public_key) ||
      Application.get_env(:bonfire_notify, :vapid_public_key)
  end
end
