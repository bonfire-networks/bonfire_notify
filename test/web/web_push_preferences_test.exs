defmodule Bonfire.Notify.WebPushPreferencesTest do
  @moduledoc """
  Verifies that web push delivery respects each subscription's Mastodon
  `alerts` (per notification type) and `policy` (per relationship) preferences.
  """
  use Bonfire.Notify.DataCase, async: false
  use Bonfire.Common.Repo

  alias Bonfire.Notify.WebPush

  @endpoint_base "https://endpoint.test"

  setup do
    Application.put_env(:bonfire_notify, :use_ex_nudge_mock, true)
    Application.put_env(:bonfire_notify, :ex_nudge_mock_response, :success)

    on_exit(fn ->
      Application.delete_env(:bonfire_notify, :use_ex_nudge_mock)
      Application.delete_env(:bonfire_notify, :ex_nudge_mock_response)
    end)

    :ok
  end

  defp subscribe!(user, opts) do
    endpoint = Keyword.get(opts, :endpoint, "#{@endpoint_base}/#{user.id}")

    data = %{
      "subscription" => %{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => "test_p256dh", "auth" => "test_auth"}
      },
      "data" =>
        %{}
        |> maybe_put("alerts", Keyword.get(opts, :alerts))
        |> maybe_put("policy", Keyword.get(opts, :policy))
    }

    {:ok, user_sub} = WebPush.subscribe(user.id, data)
    user_sub
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  # send_web_push returns a results list (one per subscription actually sent),
  # or {:error, :no_subscriptions} when everything was filtered out.
  defp sent?(result), do: is_list(result) and result != []

  describe "alerts filtering" do
    test "skips delivery when the matching alert type is disabled" do
      user = fake_user!()
      subscribe!(user, alerts: %{"favourite" => false})

      result =
        WebPush.send_web_push(user.id, "msg", notify_category: :likes)

      assert result == {:error, :no_subscriptions}
    end

    test "delivers when the matching alert type is enabled" do
      user = fake_user!()
      subscribe!(user, alerts: %{"favourite" => false, "mention" => true})

      # :replies_and_mentions maps to the "mention" alert, which is enabled
      result =
        WebPush.send_web_push(user.id, "msg", notify_category: :replies_and_mentions)

      assert sent?(result)
    end

    test "delivers when no category is given (cannot map to an alert)" do
      user = fake_user!()
      subscribe!(user, alerts: %{"favourite" => false})

      result = WebPush.send_web_push(user.id, "msg")

      assert sent?(result)
    end

    test "uses default alerts when none are stored (mention enabled by default)" do
      user = fake_user!()
      subscribe!(user, [])

      result =
        WebPush.send_web_push(user.id, "msg", notify_category: :replies_and_mentions)

      assert sent?(result)
    end
  end

  describe "policy filtering" do
    test "policy 'none' never delivers" do
      user = fake_user!()
      from = fake_user!()
      subscribe!(user, policy: "none")

      result =
        WebPush.send_web_push(user.id, "msg", notify_category: :likes, from_id: from.id)

      assert result == {:error, :no_subscriptions}
    end

    test "policy 'all' always delivers" do
      user = fake_user!()
      from = fake_user!()
      subscribe!(user, policy: "all")

      result =
        WebPush.send_web_push(user.id, "msg", notify_category: :likes, from_id: from.id)

      assert sent?(result)
    end

    test "policy 'followed' only delivers from accounts the recipient follows" do
      recipient = fake_user!()
      stranger = fake_user!()
      followed = fake_user!()

      subscribe!(recipient, policy: "followed")

      {:ok, _} = Bonfire.Social.Graph.Follows.follow(recipient, followed)

      # from a stranger the recipient does NOT follow → skipped
      assert WebPush.send_web_push(recipient.id, "msg",
               notify_category: :likes,
               from_id: stranger.id
             ) == {:error, :no_subscriptions}

      # from an account the recipient follows → delivered
      assert sent?(
               WebPush.send_web_push(recipient.id, "msg",
                 notify_category: :likes,
                 from_id: followed.id
               )
             )
    end

    test "policy 'follower' only delivers from accounts that follow the recipient" do
      recipient = fake_user!()
      follower = fake_user!()
      stranger = fake_user!()

      subscribe!(recipient, policy: "follower")

      {:ok, _} = Bonfire.Social.Graph.Follows.follow(follower, recipient)

      assert WebPush.send_web_push(recipient.id, "msg",
               notify_category: :likes,
               from_id: stranger.id
             ) == {:error, :no_subscriptions}

      assert sent?(
               WebPush.send_web_push(recipient.id, "msg",
                 notify_category: :likes,
                 from_id: follower.id
               )
             )
    end
  end
end
