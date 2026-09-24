defmodule Bonfire.Notify.EmailDigestDefaultTest do
  @moduledoc """
  How often the email digest goes out for anyone who has not chosen: Never unless the instance says otherwise, which an admin sets with the same "Email digest" dropdown, in instance settings.

  Not async, since the instance's choice is what every other test reads too.
  """
  use Bonfire.Notify.ConnCase, async: false
  use Bonfire.Common.E
  use Bonfire.Common.Settings
  use Bonfire.Common.Config

  defp frequency(user) do
    Settings.get([:notifications, :email_digest], nil,
      current_user: Bonfire.Me.Users.get_current(user.id)
    )
  end

  test "someone who has not chosen gets no digest" do
    assert frequency(fake_user!()) in [:never, "never"]
  end

  test "an admin choosing it in instance settings sets it for everyone who has not chosen" do
    account = fake_account!()
    admin = fake_admin!(account)
    someone = fake_user!()
    before = Config.get([:notifications, :email_digest])

    try do
      conn(user: admin, account: account)
      |> visit("/settings/instance/bonfire_notify")
      |> wait_async()
      |> within("#notification-email-digest-form", fn session ->
        select(session, "#notification-email-digest", "Weekly", from: "Email digest")
      end)

      assert frequency(someone) in [:weekly, "weekly"]

      # and it is the instance's, not the admin's own choice
      admin_own =
        e(Bonfire.Me.Users.get_current(admin.id), :settings, :json, :bonfire, :notifications, nil) ||
          []

      refute admin_own[:email_digest]
    after
      # an instance setting is also written to the app's config, which outlives this test's database transaction. Here rather than in `on_exit`, which runs after the database connection is gone
      Settings.put([:notifications, :email_digest], before,
        scope: :instance,
        skip_boundary_check: true
      )
    end
  end
end
