defmodule Bonfire.Notify.PostsTest do
  use Bonfire.Notify.DataCase, async: true

  import Ecto.Query

  alias Ecto.Changeset
  alias Bonfire.Notify.UserNotifications
  alias Bonfire.Notify.Notification

  alias Bonfire.Notify.Schemas.User

  describe "notify" do


    test "records a sent notification" do
      creator = fake_user!()
      notify_user = fake_user!()

      object = %{name: "You there?", summary: "Nice to meet you", creator: creator}


      Bonfire.Notify.Notify.notify(object, notify_user)


      assert [%Notification{event_type: "REPLY_CREATED"}] = UserNotifications.list(notify_user, object)
    end

  end
end
