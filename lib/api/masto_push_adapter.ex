defmodule Bonfire.Notify.API.MastoPushAdapter do
  @moduledoc """
  Mastodon-compatible push subscription API adapter.

  Implements the Mastodon push subscription API:
  - POST /api/v1/push/subscription - Create subscription
  - GET /api/v1/push/subscription - Get current subscription
  - PUT /api/v1/push/subscription - Update subscription alerts/policy
  - DELETE /api/v1/push/subscription - Delete subscription

  Also the one place that translates between Mastodon's vocabulary and ours. A subscription's `alerts` map is keyed by Mastodon's notification types (`favourite`, `reblog`, `follow_request`, …) because a Mastodon client wrote it; everywhere else in this extension speaks Bonfire verbs. Keeping the translation here is what stops `favourite` leaking into our own API and into the channels.
  """

  use Bonfire.Common.Utils
  import Untangle
  import Ecto.Query

  alias Bonfire.API.GraphQL.RestAdapter
  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription
  alias Bonfire.Notify.WebPush
  alias Bonfire.Notify.WebPushDevice
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
      case WebPushDevice.parse_subscription_data(params) do
        {:ok, parsed_attrs} ->
          user_id = id(current_user)

          device_attrs =
            parsed_attrs
            |> Map.take([:address, :auth_key, :p256dh_key])
            |> maybe_add_device_info(conn)
            # a Mastodon client is what will read anything sent to this endpoint, which is how delivery knows to shape its payload Mastodon's way rather than inferring it
            |> Map.put(:provider, :web_masto)

          # the authorisation this came from, recorded because only this endpoint knows it, and because Mastodon's payload has to carry the token so a client can fetch what it is being told about
          user_attrs =
            parsed_attrs
            |> Map.take([:alerts, :policy])
            |> Map.put(:access_token_id, e(conn.assigns, :current_token, :id, nil))

          # per the Mastodon spec this replaces whatever this authorisation was subscribed to, and leaves the person's other devices and other clients alone
          UserPushSubscription.unsubscribe_by_access_token(user_attrs[:access_token_id])

          with {:ok, device} <- WebPushDevice.find_or_create(device_attrs),
               {:ok, user_sub} <- UserPushSubscription.upsert(user_id, device.id, user_attrs) do
            respond_with_subscription({:ok, user_sub}, device, conn)
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
          RestAdapter.json(conn, format_response(user_sub, user_sub.push_device))
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
              RestAdapter.json(conn, format_response(updated, user_sub.push_device))

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

      # per the Mastodon spec, delete the person's subscriptions and not the devices themselves
      UserPushSubscription.unsubscribe_all(user_id)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{}")
    end)
  end

  # Private helpers

  defp respond_with_subscription({:ok, user_sub}, device, conn) do
    RestAdapter.json(conn, format_response(user_sub, device))
  end

  defp respond_with_subscription({:error, changeset}, _device, conn) do
    RestAdapter.error_fn({:error, changeset_error(changeset)}, conn)
  end

  # stored as sent, and parsed only when something displays it: `Bonfire.Notify.PushDevice.platform/1` does that, so a better parser later improves rows that already exist
  defp maybe_add_device_info(attrs, conn) do
    Map.put(attrs, :device_agent, Plug.Conn.get_req_header(conn, "user-agent") |> List.first())
  end

  defp maybe_put_alerts(attrs, nil, _existing), do: attrs

  defp maybe_put_alerts(attrs, new_alerts, existing_alerts) when is_map(new_alerts) do
    # merged over what was actually stored, not over a set of defaults: what this subscription wants is what its client has said it wants, and nothing else should end up in the row
    merged = Map.merge(existing_alerts || %{}, new_alerts)
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
  def format_response(%UserPushSubscription{} = user_sub, %PushDevice{} = device) do
    %{
      "id" => device.id,
      "endpoint" => device.address,
      "standard" => false,
      "server_key" => vapid_public_key(),
      "alerts" => response_alerts(user_sub.alerts),
      "policy" => UserPushSubscription.effective_policy(user_sub.policy)
    }
  end

  @doc """
  Whether a subscription will take this kind of notification, as far as Mastodon's rules are concerned.

  Two rules, both Mastodon's own. A subscription a Mastodon client created can only be sent a verb Mastodon has a name for, since its payload has to say which `notification_type` this is and the client has no way to render one it doesn't know. And a subscription carrying an `alerts` map is bound by it: the API documents every `data[alerts][*]` as defaulting to **false**, so a type the client did not ask for is a type it does not want. Absent is "no", not "no opinion".

  A subscription with neither came from somewhere else, and Mastodon's rules have nothing to say about it: the person's settings decide, which the fan-out has already applied.

  Translation happens here so the channels never handle Mastodon's vocabulary.
  """
  def accepts?(subscription, verb) do
    alerts = e(subscription, :alerts, nil)

    cond do
      masto?(subscription) and is_nil(alert_key(verb)) -> false
      is_map(alerts) and alerts != %{} -> alerted?(alerts, verb)
      true -> true
    end
  end

  defp alerted?(alerts, verb) do
    case alert_key(verb) do
      nil -> false
      key -> Map.get(alerts, key, Map.get(alerts, to_string(key), false)) == true
    end
  end

  @doc """
  Whether a Mastodon client is what will read this, and so whether its payload is ours to shape.

  Read from the device, since a push endpoint is only ever read by the software that registered it.
  """
  def masto?(subscription),
    do: e(subscription, :push_device, :provider, nil) in [:web_masto, "web_masto"]

  @doc """
  Mastodon's push payload for one subscription and one notification.

  Its own shape: seven flat keys, where ours nests what a service worker reads. `access_token` is what makes it useful, since a client is only told *that* something happened and then fetches the notification itself, so a payload without a usable token is no payload at all and the delivery is cancelled rather than sent in a shape the client cannot read. Looking the token up here rather than storing its value is what makes a revoked authorisation stop these pushes with nothing wired to it.

  `preferred_locale` is the language the fan-out assembled this in, and `notification_id` is the activity id, which is what our own Mastodon notifications API calls a notification's id.
  """
  def payload(subscription, content) do
    case access_token(subscription) do
      nil ->
        error(
          e(subscription, :access_token_id, nil),
          "No usable access token for a Mastodon push subscription, so nothing can be delivered to it"
        )

      token ->
        # `ed` rather than `e`, because a delivery job's arguments are JSON and come back with string keys, which the macro would read as missing
        {:ok,
         %{
           access_token: token,
           preferred_locale: to_string(ed(content, :locale, nil)),
           notification_id: ed(content, :activity_id, nil),
           notification_type: to_string(alert_key(ed(content, :verb, nil))),
           icon: ed(content, :icon, nil),
           title: ed(content, :title, nil),
           body: ed(content, :body, nil)
         }}
    end
  end

  # asked rather than called, since this extension doesn't depend on `bonfire_open_id` and an instance can run without OAuth at all. No token module means no Mastodon-shaped deliveries, which is right rather than a failure
  defp access_token(subscription) do
    with token_id when is_binary(token_id) <- e(subscription, :access_token_id, nil),
         user_id when is_binary(user_id) <- e(subscription, :id, nil),
         {:ok, token} <-
           maybe_apply(
             Bonfire.OpenID.Provider.Tokens,
             :get_active_for_user,
             [user_id, token_id],
             fallback_return: nil
           ) do
      e(token, :value, nil)
    else
      _ -> nil
    end
  end

  @doc """
  Mastodon's name for a Bonfire verb's notifications, or nil for a verb Mastodon has no type for.

  A verb with no Mastodon name cannot be muted by a Mastodon client, since the client has no way to refer to it, and cannot be delivered to one either.

  Takes the verb as an atom or as the string a delivery job carries it as, since job arguments are JSON and come back with everything spelled out.
  """
  def alert_key(verb) when is_binary(verb),
    do: alert_key(Bonfire.Common.Types.maybe_to_atom!(verb))

  def alert_key(verb) when is_atom(verb) and not is_nil(verb),
    do: alert_keys() |> Map.get(verb)

  def alert_key(_), do: nil

  defp alert_keys do
    Config.get([__MODULE__, :alert_keys], %{},
      name: l("Mastodon notification types"),
      description: l("What each kind of notification is called in Mastodon's API.")
    )
  end

  # every documented type has to be present in a response, so the one place a default is legitimate is here: the API says each defaults to false, and a key we leave out is a key a client cannot display. Only this module builds this shape
  defp response_alerts(stored) do
    stored = stored || %{}

    Map.new(response_types(), fn type ->
      {type, Map.get(stored, type, Map.get(stored, String.to_atom(type), false)) == true}
    end)
  end

  defp response_types do
    Config.get([__MODULE__, :response_types], [],
      name: l("Mastodon push alert types"),
      description:
        l("Which notification types a Mastodon push subscription response has to account for.")
    )
  end

  defp vapid_public_key do
    Application.get_env(:ex_nudge, :vapid_public_key) ||
      Application.get_env(:bonfire_notify, :vapid_public_key)
  end
end
