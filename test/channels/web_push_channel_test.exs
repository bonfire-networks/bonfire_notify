defmodule Bonfire.Notify.WebPushChannelTest do
  @moduledoc """
  Web push as a delivery channel: where someone can be reached, and what each answer from a push service means for the job that sent it.

  The answer decides the job's fate, so the mapping is the behaviour worth pinning. An endpoint the service says is gone is deactivated and the job cancelled, since retrying a dead endpoint five times only delays the same failure. A rate limit is a snooze, a server error is worth retrying, and a rejected request means our own VAPID configuration is wrong, which retrying cannot fix either.

  A target is re-read scoped to the person it was meant for, because browsers are shared: an endpoint that has since been claimed by another account must not receive the first account's notification.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E

  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription
  alias Bonfire.Notify.WebPush
  import Bonfire.Common.Config, only: [repo: 0]

  setup do
    configure_web_push()

    user = fake_user!()
    other = fake_user!()

    {:ok, link} = subscribe(user, "https://push.bonfire.local/one")

    {:ok, user: user, other: other, link: link}
  end

  defp subscribe(user, endpoint) do
    WebPush.subscribe(user.id, valid_push_subscription_map(endpoint))
  end

  defp content, do: %{title: "Alice", body: "said something", url: "/post/1", tag: "abc"}

  defp device(link), do: repo().get!(PushDevice, link.push_device_id)

  defp deliver(user, link, response) do
    configure_web_push(response)
    assert {:ok, target} = WebPush.target(link.push_device_id, user.id)
    WebPush.deliver(target, content())
  end

  test "every browser someone has subscribed is a target", %{user: user, link: link} do
    {:ok, second} = subscribe(user, "https://push.bonfire.local/two")

    targets = WebPush.targets([user.id])

    assert length(targets) == 2

    assert Enum.sort(Enum.map(targets, & &1.target_id)) ==
             Enum.sort([link.push_device_id, second.push_device_id])

    assert Enum.all?(targets, &(&1.user_id == user.id))
  end

  test "somebody with no subscription has no targets", %{other: other} do
    assert WebPush.targets([other.id]) == []
  end

  describe "what a subscription can decide" do
    test "one subscribed from our own UI carries no alerts, so settings alone decide", %{
      user: user,
      link: link
    } do
      refute link.alerts,
             "subscribing says where to reach someone, so nothing about what to send is stored here"

      assert [_] = WebPush.targets([user.id], :like)
      assert [_] = WebPush.targets([user.id], :mention)
    end

    test "one a Mastodon client made takes only the types it asked for", %{user: user, link: link} do
      # what that API documents: every alert defaults to false, so the map is the whole list of what this subscription wants
      assert {:ok, _} =
               UserPushSubscription.upsert(user.id, link.push_device_id, %{
                 alerts: %{"mention" => true}
               })

      assert [_] = WebPush.targets([user.id], :mention)

      assert WebPush.targets([user.id], :like) == [],
             "a type the client left out is a type it does not want, not one for us to decide"
    end

    test "a verb Mastodon has no name for is not sent to one of its clients", %{
      user: user,
      link: link
    } do
      assert {:ok, _} =
               UserPushSubscription.upsert(user.id, link.push_device_id, %{
                 alerts: %{"mention" => true}
               })

      # the client has no name to refer to it by, and no way to render it if it arrived
      assert WebPush.targets([user.id], :some_verb_of_our_own) == []
    end

    test "a subscription set not to be pushed to takes nothing at all", %{user: user, link: link} do
      assert {:ok, _} =
               UserPushSubscription.upsert(user.id, link.push_device_id, %{policy: "none"})

      assert WebPush.targets([user.id], :like) == []
      assert WebPush.targets([user.id], :mention) == []
    end
  end

  test "a target belongs to one person, so another cannot be delivered to through it", %{
    user: user,
    other: other,
    link: link
  } do
    assert {:ok, _} = WebPush.target(link.push_device_id, user.id)

    assert {:error, :inactive} = WebPush.target(link.push_device_id, other.id),
           "a shared browser must not hand one account's notification to another"
  end

  test "an inactive subscription is not a target any more", %{user: user, link: link} do
    assert {:ok, _} = WebPush.target(link.push_device_id, user.id)

    PushDevice.mark_status(device(link), {:expired, :gone})

    assert {:error, :inactive} = WebPush.target(link.push_device_id, user.id)
    assert WebPush.targets([user.id]) == []
  end

  test "a delivered push is recorded as delivered", %{user: user, link: link} do
    assert :ok = deliver(user, link, :success)

    assert_receive {:web_push_sent, _subscription, payload, opts}

    assert Jason.decode!(payload)["title"] == "Alice"
    assert opts[:ttl] == nil or is_integer(opts[:ttl])

    recorded = device(link)
    assert recorded.last_status == :success
    assert recorded.active == true
    assert recorded.last_error == nil
  end

  test "an expired endpoint is deactivated and the job cancelled", %{user: user, link: link} do
    assert {:cancel, :inactive} = deliver(user, link, :expired)

    recorded = device(link)
    assert recorded.active == false
    assert recorded.last_status == :expired
  end

  test "a 404 or 410 means gone too", %{user: user} do
    for status <- [404, 410] do
      {:ok, link} = subscribe(user, "https://push.bonfire.local/gone-#{status}")

      assert {:cancel, :inactive} = deliver(user, link, {:http_error, status})
      assert device(link).active == false
    end
  end

  test "a rate limit is a snooze rather than a failure", %{user: user, link: link} do
    assert {:snooze, seconds} = deliver(user, link, {:http_error, 429})
    assert is_integer(seconds) and seconds > 0

    assert device(link).active == true,
           "a rate-limited endpoint is still a good endpoint"
  end

  test "a server error is worth retrying", %{user: user, link: link} do
    assert {:error, {:http_error, 503}} = deliver(user, link, {:http_error, 503})

    recorded = device(link)
    assert recorded.active == true
    assert recorded.last_status == :error
  end

  test "a rejected request is our configuration, so it is not retried", %{user: user, link: link} do
    for status <- [400, 401, 403] do
      assert {:cancel, {:http_error, ^status}} = deliver(user, link, {:http_error, status})
    end

    assert device(link).active == true,
           "the endpoint is fine, it is our VAPID keys that are not"
  end

  test "a payload too large for the service is not retried either", %{user: user, link: link} do
    assert {:cancel, :payload_too_large} = deliver(user, link, :payload_too_large)
  end

  test "a delivery shapes its own payload, and refuses finished bytes", %{user: user, link: link} do
    configure_web_push(:success)
    assert {:ok, target} = WebPush.target(link.push_device_id, user.id)

    assert :ok = WebPush.deliver(target, content())

    assert_receive {:web_push_sent, _subscription, payload, _opts}

    assert Jason.decode!(payload)["title"] == "Alice",
           "the content is shaped here, because which shape this endpoint's client reads is known here"

    # bytes cannot be reshaped for a target, so a caller that hands them over is refused loudly rather than having its payload sent as a string of nulls
    assert {:cancel, _} = WebPush.deliver(target, Jason.encode!(content()))
    refute_receive {:web_push_sent, _, _, _}
  end
end
