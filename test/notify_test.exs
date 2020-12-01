defmodule Bonfire.Notifications.PostsTest do
  use Bonfire.Notifications.DataCase, async: true

  import Ecto.Query

  alias Ecto.Changeset
  alias Bonfire.Notifications.UserNotifications
  alias Bonfire.Notifications.Notification

  alias Bonfire.Notifications.Schemas.User

  describe "notify" do


    test "records a sent notification" do
      creator = fake_user!()
      notify_user = fake_user!()

      object = %{name: "You there?", summary: "Nice to meet you", creator: creator}


      Bonfire.Notifications.Notify.notify(object, notify_user)


      assert [%Notification{event_type: "REPLY_CREATED"}] = UserNotifications.list(notify_user, object)
    end

  end
end
