defmodule Bonfire.Notifications.Test.FakeHelpers do

  alias Bonfire.Data.Identity.Account
  alias Bonfire.Notifications.Fake
  alias Bonfire.Notifications.{Accounts, Users}
  import ExUnit.Assertions

  @repo Application.get_env(:bonfire_notifications, :repo_module)

  def fake_account!(attrs \\ %{}) do
    # cs = Accounts.signup_changeset(Fake.account(attrs))
    # assert {:ok, account} = @repo.insert(cs)
    # account
  end

  def fake_user!(%{}=account, attrs \\ %{}) do
    # assert {:ok, user} = Users.create(Fake.user(attrs), account)
    # user
  end

end
