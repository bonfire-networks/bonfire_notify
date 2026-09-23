defmodule Bonfire.Notify.LiveChannelTest do
  @moduledoc """
  Live delivery as a channel: what a connected client shows when a notification arrives, whether an open page (as a toast) or the native app's SSE stream.

  It is what push falls back to wherever push does not work, so it follows the same Push switch, and it goes through the fan-out like every other channel. That is where a recipient's experience of the activity is worked out and their switch is asked, and a live notification sent from anywhere else reached people who had switched that kind off.

  Each test subscribes to the recipient's notifications feed, which is what `Bonfire.UI.Common.NotificationLive` and the SSE stream subscribe to.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E

  alias Bonfire.Notify.FanOut

  setup do
    alice = Bonfire.Me.Fake.fake_user!()
    bob = Bonfire.Me.Fake.fake_user!()

    {:ok, bobs_post} =
      Bonfire.Posts.publish(
        current_user: bob,
        post_attrs: %{post_content: %{html_body: "something for alice to like"}},
        boundary: "public"
      )

    # as a connected client does (this is the SSE stream's own call), so the test hears what it would
    Phoenix.PubSub.subscribe(
      Bonfire.Common.PubSub,
      to_string(Bonfire.Social.Feeds.my_feed_id(:notifications, bob))
    )

    {:ok, alice: alice, bob: bob, bobs_post: bobs_post}
  end

  defp like_and_fan_out(alice, bob, bobs_post) do
    {:ok, like} = Bonfire.Social.Likes.like(alice, bobs_post)
    like_activity = e(like, :activity, nil)

    # nothing yet: live delivery is the fan-out's to send, so a like on its own shows nothing
    refute_received {Bonfire.UI.Common.Notifications, _}

    FanOut.notify(like_activity, %{recipients: [%{"user_id" => bob.id}], feeds: []})
  end

  test "a connected client gets the notification from the fan-out", %{
    alice: alice,
    bob: bob,
    bobs_post: post
  } do
    like_and_fan_out(alice, bob, post)

    assert_receive {Bonfire.UI.Common.Notifications, %{} = notification}
    assert e(notification, :activity_id, nil)
    # the contrast for the test below: a recipient who chose no language reads the default
    assert e(notification, :title, "") =~ "liked"

    # and only once: `LivePush` flashes too when this channel is missing, and both at once would show one like twice
    refute_receive {Bonfire.UI.Common.Notifications, _}, 500
  end

  test "it arrives worded in the recipient's own language, not the sender's", %{
    alice: alice,
    bob: bob,
    bobs_post: post
  } do
    # worded once per language by `Bonfire.Notify.Deliveries`, from the recipient's own setting, since the process sending it knows nothing of who reads it. French, because the test env compiles only en, fr, es and it (`config/ember.exs`), and "liked" is translated in fr
    Bonfire.Common.Settings.put([Bonfire.Common.Localise.Cldr, :default_locale], "fr",
      current_user: bob
    )

    like_and_fan_out(alice, bob, post)

    assert_receive {Bonfire.UI.Common.Notifications, %{} = notification}
    assert e(notification, :title, "") =~ "a aimé"
    refute e(notification, :title, "") =~ "liked"
  end

  test "switched off under Push, a connected client gets nothing either", %{
    alice: alice,
    bob: bob,
    bobs_post: post
  } do
    # the key the panel's Push switch writes for the Reactions row
    Bonfire.Common.Settings.put([:notifications, :push, :react], false, current_user: bob)

    like_and_fan_out(alice, bob, post)

    refute_receive {Bonfire.UI.Common.Notifications, _}, 500
  end
end
