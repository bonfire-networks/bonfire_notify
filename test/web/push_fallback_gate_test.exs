defmodule Bonfire.Notify.PushFallbackGateTest do
  @moduledoc """
  Whether an open page shows a notification itself, which it should do only when push is not doing it.

  Two facts decide it and they live in different places: the browser knows whether it holds a push subscription, and only the server knows whether the person reading this page is still linked to it. A shared browser is what makes those different questions, since somebody turning push off leaves the browser's subscription in place for everyone else signed in there.
  """
  use Bonfire.Notify.ConnCase, async: false

  alias Bonfire.Notify.WebPush
  alias Bonfire.UI.Common.Notifications

  @endpoint_url "https://push.bonfire.local/gated"

  setup do
    configure_web_push()
    {:ok, user: fake_user!()}
  end

  describe "WebPush.subscribed_at?/2" do
    test "is true while this person is linked to the device at that endpoint", %{user: user} do
      assert {:ok, _} = WebPush.subscribe(user.id, valid_push_subscription_map(@endpoint_url))

      assert WebPush.subscribed_at?(user.id, @endpoint_url)
    end

    test "is false for somebody else's subscription to the same browser", %{user: user} do
      other = fake_user!()
      assert {:ok, _} = WebPush.subscribe(other.id, valid_push_subscription_map(@endpoint_url))

      refute WebPush.subscribed_at?(user.id, @endpoint_url),
             "the device is reachable, but not for this person, so their page is the only thing that can tell them"
    end

    test "is false once this person unsubscribes, even though the browser keeps its subscription",
         %{user: user} do
      other = fake_user!()
      assert {:ok, _} = WebPush.subscribe(user.id, valid_push_subscription_map(@endpoint_url))
      assert {:ok, _} = WebPush.subscribe(other.id, valid_push_subscription_map(@endpoint_url))

      assert {:ok, :others_remain} = WebPush.unsubscribe(user.id, @endpoint_url)

      refute WebPush.subscribed_at?(user.id, @endpoint_url)
      assert WebPush.subscribed_at?(other.id, @endpoint_url), "and the others are untouched"
    end

    test "is false for an endpoint nobody registered, or for nothing at all", %{user: user} do
      refute WebPush.subscribed_at?(user.id, "https://push.bonfire.local/never-seen")
      refute WebPush.subscribed_at?(user.id, nil)
      refute WebPush.subscribed_at?(nil, @endpoint_url)
    end
  end

  describe "the page's own notification" do
    setup %{user: user} do
      {:ok, view, _html} = live(conn(user: user, account: user.account), "/notifications")

      feed_id =
        Bonfire.Social.Feeds.my_feed_id(:notifications, current_user: user)

      {:ok, view: view, feed_id: feed_id}
    end

    # what the notification hook sends once it has read the browser's subscription. `notifications-1` is the instance the layout renders: the one in `PersistentLive` is a sticky child LiveView, which a test does not render.
    defp report(view, params) do
      view
      |> element("#notifications-1")
      |> render_hook("push_state", params)
    end

    defp notify(view, feed_id) do
      Notifications.notify_broadcast([feed_id], %{
        title: "Something happened",
        message: "a reply you would want",
        url: "/notifications",
        activity_id: "01M30EE62MFGD828WZQHR2C54E"
      })

      # Proof it arrived, before anything is concluded from what the page shows: the same broadcast drives the OS notification the hook may fire, and a page that renders no toast because nothing reached it would otherwise look exactly like the gate working.
      assert_push_event(view, "notify:notifications-2", %{title: "Something happened"})

      render(view)
    end

    test "shows as a toast where push is not working on this device", %{
      view: view,
      feed_id: feed_id
    } do
      report(view, %{"active" => false, "endpoint" => nil})

      assert notify(view, feed_id) =~ "Something happened",
             "with nothing else showing it, the page is where this person finds out"
    end

    test "stays silent where push is working for this person on this device", %{
      view: view,
      feed_id: feed_id,
      user: user
    } do
      assert {:ok, _} = WebPush.subscribe(user.id, valid_push_subscription_map(@endpoint_url))
      report(view, %{"active" => true, "endpoint" => @endpoint_url})

      refute notify(view, feed_id) =~ "Something happened",
             "the service worker is already showing it, so a toast would be the same thing twice"
    end

    test "shows as a toast when the browser is subscribed but this person is not", %{
      view: view,
      feed_id: feed_id
    } do
      other = fake_user!()
      assert {:ok, _} = WebPush.subscribe(other.id, valid_push_subscription_map(@endpoint_url))

      report(view, %{"active" => true, "endpoint" => @endpoint_url})

      assert notify(view, feed_id) =~ "Something happened",
             "a shared browser's subscription belongs to whoever registered it, and nothing would reach this person without the page"
    end
  end
end
