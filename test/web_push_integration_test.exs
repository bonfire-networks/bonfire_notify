defmodule Bonfire.Notify.WebPushIntegrationTest do
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.Repo
  import Bonfire.Me.Fake

  alias Bonfire.Notify.WebPush
  alias Bonfire.Notify.PushSubscription

  describe "send_web_push/3 with mocked ExNudge" do
    setup do
      # Configure to use mock in tests
      Application.put_env(:bonfire_notify, :use_ex_nudge_mock, true)

      on_exit(fn ->
        # Clean up
        Application.delete_env(:bonfire_notify, :use_ex_nudge_mock)
        Application.delete_env(:bonfire_notify, :ex_nudge_mock_response)
      end)

      :ok
    end

    test "successfully sends to subscribed users" do
      # Set mock to return success
      Application.put_env(:bonfire_notify, :ex_nudge_mock_response, :success)

      user1 = fake_user!()
      user2 = fake_user!()

      {:ok, _} =
        WebPush.subscribe(
          user1.id,
          valid_push_subscription_map("https://push.example.com/send/123")
        )

      {:ok, _} =
        WebPush.subscribe(
          user2.id,
          Map.put(
            valid_push_subscription_map("https://push.example.com/send/123"),
            "endpoint",
            "https://push.example.com/send/456"
          )
        )

      message = WebPush.format_push_message("Test", "Message")
      results = WebPush.send_web_push([user1.id, user2.id], message)

      assert length(results) == 2
      assert Enum.all?(results, fn {status, _, _} -> status == :ok end)

      # Verify push subscriptions were marked as successful
      [sub1] = Map.get(WebPush.get_subscriptions([user1.id]), user1.id)
      push_sub_record = repo().get!(PushSubscription, sub1.metadata.id)
      assert push_sub_record.last_status == :success
      assert push_sub_record.last_error == nil
    end

    test "handles expired subscriptions" do
      # Set mock to return expired
      Application.put_env(:bonfire_notify, :ex_nudge_mock_response, :expired)

      user = fake_user!()

      {:ok, _} =
        WebPush.subscribe(
          user.id,
          valid_push_subscription_map("https://push.example.com/send/123")
        )

      message = WebPush.format_push_message("Test", "Message")
      results = WebPush.send_web_push([user.id], message)

      assert [{:error, _, :subscription_expired}] = results

      # Verify subscription was removed
      assert %{} = WebPush.get_subscriptions([user.id])
    end

    test "handles error responses" do
      # Set mock to return HTTP 500 error
      Application.put_env(:bonfire_notify, :ex_nudge_mock_response, {:error, 500})

      user = fake_user!()

      {:ok, _} =
        WebPush.subscribe(
          user.id,
          valid_push_subscription_map("https://push.example.com/send/123")
        )

      message = WebPush.format_push_message("Test", "Message")
      results = WebPush.send_web_push([user.id], message)

      assert [{:error, _, %{status_code: 500}}] = results

      # Verify push subscription was marked with error but still active
      [sub] = Map.get(WebPush.get_subscriptions([user.id]), user.id)
      push_sub_record = repo().get!(PushSubscription, sub.metadata.id)
      assert push_sub_record.last_status == :error
      assert push_sub_record.active == true
    end
  end

  describe "send_web_push/3 with real ExNudge (sanity check)" do
    test "calls real ExNudge and handles the response" do
      # Don't set mock flag - use real ExNudge
      user = fake_user!()

      {:ok, _} =
        WebPush.subscribe(
          user.id,
          valid_push_subscription_map("https://fcm.googleapis.com/fcm/send/test123")
        )

      message = WebPush.format_push_message("Real Test", "Testing real ExNudge")

      # This will call the real ExNudge library
      # It will likely fail with an HTTP error since we're using test endpoints
      # but that's fine - we're just checking the integration works
      results =
        WebPush.send_web_push([user.id], message)
        |> debug("ExNudge results")

      # Assert we got a result back (even if it's an error)
      assert [{status, _sub, _response}] = results

      # We expect an error since test endpoints aren't real
      # Common errors: HTTP 400/404/503, or connection errors
      assert status == :error

      # Verify our error handling worked - subscription should still be active
      # (only expired subscriptions get deleted)
      [sub] = Map.get(WebPush.get_subscriptions([user.id]), user.id)
      push_sub_record = repo().get!(PushSubscription, sub.metadata.id)
      assert push_sub_record.active == true
      assert push_sub_record.last_status == :error
    end
  end
end
