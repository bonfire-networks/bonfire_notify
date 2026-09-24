defmodule Bonfire.Notify.PreferencesTest do
  @moduledoc """
  Whether someone wants to be told about something, on a given channel.

  The one question the fan-out asks before writing a delivery, so this is where "what am I notified about" is decided for every client and every channel. Notifications are opt-out: silence has to be chosen, not assumed, or a new kind of notification would arrive switched off for everyone.

  Switches are per **notification category** and per channel, which is the grain a person is shown: one row in the preferences panel, one switch per channel, and the same category key that decides whether a kind appears in their notifications feed. So mentions on a phone and nothing in a browser is expressible without any per-device state.

  A category is a set of verbs rather than a verb, which is why the two are not interchangeable: the Mentions row covers the `create` verb, a reply is its own verb, and verbs no category covers fall to `:other`, and below that to the coarse keys the old UI wrote so nobody's existing choice is lost.

  The settings have to be read from the recipient they were loaded with, which is why `Bonfire.Notify.Recipients` preloads both theirs and their account's.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.Settings
  use Bonfire.Common.Utils

  alias Bonfire.Notify.Preferences
  alias Bonfire.Social.Notifications

  setup do
    account = fake_account!()
    {:ok, user: fake_user!(account), account: account}
  end

  # `Settings.put/3` hands back a context rather than a user, and the fan-out reads settings off the recipient it was given, so the updated one is what the next read has to use
  defp set(user, keys, value),
    do: current_user(Settings.put(keys, value, current_user: user))

  test "with nothing chosen, everything is on", %{user: user} do
    assert Preferences.enabled?(user, :like, :web_push)
    assert Preferences.enabled?(user, :create, :native_push)

    assert Preferences.enabled?(user, :some_verb_nobody_declared, :web_push),
           "a kind nobody has declared a preference for still arrives, since these are opt-out"
  end

  @tag skip:
         "one Push switch covers every push channel, a phone included; not on one device is that device's own switch (`policy: \"none\"`)"
  test "a switch is per category and per channel", %{user: user} do
    user = set(user, [:notifications, :web_push, :react], false)

    refute Preferences.enabled?(user, :like, :web_push)

    assert Preferences.enabled?(user, :like, :native_push),
           "switching likes off in a browser says nothing about a phone"

    assert Preferences.enabled?(user, :create, :web_push),
           "and says nothing about other categories"
  end

  test "a switch is per category, and one Push switch covers every push channel", %{user: user} do
    user = set(user, [:notifications, :push, :react], false)

    refute Preferences.enabled?(user, :like, :web_push)

    refute Preferences.enabled?(user, :like, :native_push),
           "a phone follows the one Push switch as a browser does"

    assert Preferences.enabled?(user, :create, :web_push),
           "and says nothing about other categories"
  end

  test "the switch turns on what the activity was for this person, not what was stored", %{
    user: user
  } do
    user = set(user, [:notifications, :push, :mention], false)

    refute Preferences.enabled?(user, :mention, :web_push),
           "switching Mentions off has to reach a post that names them"

    assert Preferences.enabled?(user, :reply, :web_push),
           "a reply is its own row, so Mentions says nothing about it"

    # the same post, for somebody it does not name: stored identically, and not a mention to them
    assert Preferences.enabled?(user, :write, :web_push),
           "a post that merely reached them is not a mention of them"
  end

  test "it is the same key the notifications feed switch uses, on another channel", %{user: user} do
    # one row, two switches: what appears in the feed, and what is pushed
    [_, _, category] = Notifications.show_in_centre_key(:react)

    user = set(user, [:notifications, :push, category], false)

    refute Preferences.enabled?(user, :like, :web_push)
    refute Preferences.enabled?(user, :like, :native_push)

    assert Notifications.show_in_centre?(:react, current_user: user),
           "switching the push off must not hide it from the feed as well"
  end

  @tag skip:
         "one Push switch covers every push channel, so the catch-all does too; see the test below"
  test "`:other` catches the kinds with no category of their own", %{user: user} do
    user = set(user, [:notifications, :web_push, :other], false)

    refute Preferences.enabled?(user, :some_verb_nobody_declared, :web_push)

    assert Preferences.enabled?(user, :some_verb_nobody_declared, :native_push),
           "the catch-all is per channel too"
  end

  test "`:other` catches the kinds with no category of their own, on every push channel", %{
    user: user
  } do
    user = set(user, [:notifications, :push, :other], false)

    refute Preferences.enabled?(user, :some_verb_nobody_declared, :web_push)
    refute Preferences.enabled?(user, :some_verb_nobody_declared, :native_push)

    assert Notifications.show_in_centre?(:other, current_user: user),
           "switching Other's push off must not hide it from the feed as well"
  end

  test "`:other` is the switch for the rest, not a default for every category", %{user: user} do
    user = set(user, [:notifications, :push, :other], false)

    # the positive first: the switch did take, for what it covers
    refute Preferences.enabled?(user, :some_verb_nobody_declared, :web_push)

    assert Preferences.enabled?(user, :like, :web_push),
           "switching Other off must not silence a category nobody touched"
  end

  test "a switch of its own outranks the catch-all", %{user: user} do
    user =
      user
      |> set([:notifications, :push, :other], false)
      |> set([:notifications, :push, :react], true)

    assert Preferences.enabled?(user, :like, :web_push)
    refute Preferences.enabled?(user, :some_verb_nobody_declared, :web_push)
  end

  describe "the keys the old UI wrote" do
    test "a coarse switch still turns its verbs off", %{user: user} do
      # one key per group of verbs, which is what the settings hold until the new switches replace them
      user = set(user, [:push_notifications, :likes], false)

      refute Preferences.enabled?(user, :like, :web_push)
      refute Preferences.enabled?(user, :like, :native_push)

      assert Preferences.enabled?(user, :follow, :web_push),
             "a group's key only covers the verbs in that group"
    end

    test "a new switch outranks the old key", %{user: user} do
      user = set(user, [:push_notifications, :likes], false)
      refute Preferences.enabled?(user, :like, :web_push)

      user = set(user, [:notifications, :push, :react], true)

      assert Preferences.enabled?(user, :like, :web_push),
             "nothing is migrated, so the new choice has to win where both exist"
    end

    test "the old email switch still sends mentions and replies as they happen", %{user: user} do
      user = set(user, [:email_notifications, :reply_or_mentions], true)

      assert Preferences.enabled?(user, :mention, :email)
      assert Preferences.enabled?(user, :reply, :email)

      refute Preferences.enabled?(user, :like, :email),
             "it only ever covered mentions and replies"
    end

    test "a new email choice outranks the old switch", %{user: user} do
      user =
        user
        |> set([:email_notifications, :reply_or_mentions], true)
        |> set([:notifications, :email, :mention], false)

      refute Preferences.enabled?(user, :mention, :email)
      assert Preferences.enabled?(user, :reply, :email)
    end

    test "a verb no coarse key covers is unaffected by them", %{user: user} do
      user = set(user, [:push_notifications, :likes], false)

      assert Preferences.enabled?(user, :flag, :web_push)
    end
  end
end
