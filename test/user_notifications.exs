defmodule Bonfire.Notifications.UserNotificationsTest do
  use Bonfire.Notifications.DataCase, async: true

  alias Bonfire.Notifications.UserNotifications
  alias Bonfire.Notifications.Notification


  describe "record_reply_created/2" do
    test "inserts a notification record" do
      user = fake_user!()
      reply = %Reply{id: "xyz", post_id: "abc"}
      {:ok, notification} = UserNotifications.record_notification(user, reply, "TEST")

      assert notification.topic == "post:abc"
      assert notification.state_dismissed == false
      assert notification.event_type == "TEST"
      assert notification.data == %{"post_id" => "abc", "reply_id" => "xyz"}
    end
  end

  describe "dismiss_topic/2" do
    test "transitions notifications to dismissed" do
      user = fake_user!()

      # {:ok, ^topic} = UserNotifications.dismiss_topic(user, topic)

      # notifications = UserNotifications.list(user, post)
      # assert Enum.count(notifications) == 2

      # assert Enum.all?(notifications, fn notification ->
      #          notification.state_dismissed == true
      #        end)
    end

    test "does not touch timestamp on already dismissed notifications" do
      user = fake_user!()

      # topic = "post:#{post_id}"
      # earlier_time = ~N[2018-11-01 10:00:00.000000]
      # now = ~N[2018-11-02 10:00:00.000000]

      # {:ok, notification} = UserNotifications.record_post_created(user, post)
      # {:ok, ^topic} = UserNotifications.dismiss_topic(user, topic, earlier_time)
      # {:ok, ^topic} = UserNotifications.dismiss_topic(user, topic, now)

      # updated_notification = Repo.get(Notification, notification.id)
      # assert updated_notification.updated_at == earlier_time
    end
  end
end
