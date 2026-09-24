defmodule Bonfire.Notify.Preferences do
  @moduledoc """
  Whether a person wants to be told about something, on a given channel.

  The one place that answers it, so the fan-out asks a question rather than reading settings keys. Preferences are per notification category and per channel, the same categories a person sees switches for; older coarse keys are read as a fallback, so nobody's existing choice is lost while the switches catch up.

  Reading takes the recipient's loaded settings, so `Bonfire.Notify.Recipients` preloads both the user's and their account's: reading one without the other is how account-scope preferences are silently ignored today.
  """
  use Bonfire.Common.Settings
  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Untangle
  import Bonfire.Common.Utils, only: [maybe_apply: 4]

  @doc """
  Whether to deliver an activity of this verb to this person on this channel.

  Keyed by **notification category** and channel, `[:notifications, <channel>, <category>]`, with `:other` as the catch-all for a verb no category covers. Defaults to true, since these are opt-out.

  The channel in the key is the switch a person sees, not the delivery channel asked about: every push channel (`:web_push`, `:native_push`) follows the one `:push` switch, as declared in this module's `channels` config.

  Categories rather than verbs because a category is what a person is shown and switches: the same key that decides whether a kind appears in their notifications feed (`[:notifications, :centre, <category>]`) decides whether it is pushed, so one row in the UI is one setting per channel.

  A category is not a verb and is not derivable from one: which grouping a notification belongs to can depend on the object as well (a direct message is a `create` of a `Message`, which is why `Bonfire.Notify.Content` overrides the verb by object type) and on the recipient's own relation to it (a mention is a tag pointing at *them*). So `Bonfire.Social.Notifications` is asked rather than copied here, since it owns both what each category covers and how exact that answer is, and this reads whatever it is told. Anything no category covers falls to the catch-all rather than getting a key of its own.

  A person who has never touched these switches still has their old coarse ones honoured: those hold one key per group of verbs (`[:push_notifications, :likes]` and friends), so they are read as a fallback rather than migrated, and a new choice takes precedence over the old one.
  """
  def enabled?(user, experience, delivery_channel \\ :push) do
    # the switch a person sees, which one delivery channel shares with others: every push channel follows the one Push switch
    case preference_channel(delivery_channel) do
      :email -> emailed_as_it_happens?(user, experience)
      channel -> wants?(user, experience, channel)
    end
  end

  @doc """
  The notification categories this person leaves to the email digest: those with a row whose Email setting is unset (Digest), neither Instant (`true`, already emailed as it happened, including through the old email switch) nor Off (`false`).

  As category keys, which is what the notifications feed's `notification_categories:` filter takes, so the digest selects exactly what the switches say.
  """
  def digest_categories(user) do
    Bonfire.Common.Utils.maybe_apply(Bonfire.Social.Notifications, :categories_shown, [:row],
      fallback_return: []
    )
    |> Enum.map(fn {key, _category} -> key end)
    |> Enum.filter(fn key ->
      is_nil(setting(user, [:notifications, :email, key])) and not old_email_switch?(user, key)
    end)
  end

  # email is per category, in three states: `true` sends as it happens ("Immediately"), `false` never ("Off"), and unset leaves it to the digest, so a new kind of notification never starts sending everybody one email each
  defp emailed_as_it_happens?(user, experience) do
    case switch(user, experience, :email) do
      nil -> coarse_email?(user, experience)
      chosen -> chosen in [true, "true"]
    end
  end

  # the one email switch the old UI wrote (mentions and replies, sent as they happen), read as a fallback so nobody's choice is lost, for the categories it covered until a new choice is made for them. From config, like `push_categories`, and gone with the key it serves
  defp coarse_email?(user, experience), do: old_email_switch?(user, category_of(experience))

  defp old_email_switch?(user, category) do
    case Map.get(email_categories(), category) do
      nil -> false
      keys -> Settings.get(keys, nil, context: user) in [true, "true"]
    end
  end

  defp email_categories do
    Config.get([__MODULE__, :email_categories], %{},
      name: l("Old email preference keys"),
      description: l("Which old email setting each kind of notification still honours.")
    )
  end

  defp wants?(user, experience, channel) do
    case switch(user, experience, channel) do
      nil -> coarse_enabled?(user, experience, channel)
      chosen -> chosen != false
    end
    |> debug("deliver #{inspect(experience)} on #{inspect(channel)}?")
  end

  # the one switch that answers for this kind: its category's, or `:other`'s for a kind no category covers. Only then: `:other` is the switch for the rest, not a default for every category, so switching it off leaves an untouched category alone. And never a bare verb as a key, which could collide with a category of the same name meaning something else (the `mention` category selects the `create` verb, while `mention` is also a verb in its own right)
  defp switch(user, experience, channel) do
    case category_of(experience) do
      nil -> setting(user, [:notifications, channel, :other])
      category -> setting(user, [:notifications, channel, category])
    end
  end

  # asked rather than copied, since `bonfire_social` owns the categories a person is shown switches for. With no social there are no activities to deliver anyway
  defp category_of(experience) do
    maybe_apply(
      Bonfire.Social.Notifications,
      :category_for,
      [experience],
      fallback_return: nil
    )
  end

  defp setting(user, keys), do: Settings.get(keys, nil, context: user)

  # a delivery channel's switch, from config, else its own name
  defp preference_channel(delivery_channel) do
    Config.get([__MODULE__, :channels], %{},
      name: l("Notification switch per delivery channel"),
      description: l("Which switch each way of delivering a notification follows.")
    )
    |> Map.get(delivery_channel, delivery_channel)
  end

  # the keys the old UI wrote, one per group of verbs, and only for push: email has none of its own yet
  defp coarse_enabled?(user, verb, :push) do
    case category(verb) do
      nil -> true
      category -> Settings.get([:push_notifications, category], true, context: user) != false
    end
  end

  defp coarse_enabled?(_user, _verb, _channel), do: true

  @doc """
  Which preference key a verb is filtered by, from config, or nil for a verb that names none.

  Coarse keys are what the current settings hold, one per group of verbs rather than one per verb, so the mapping is declared rather than written here, and it goes away with the keys it serves.
  """
  def category(verb) do
    push_categories() |> Map.get(verb)
  end

  defp push_categories do
    Config.get([__MODULE__, :push_categories], %{},
      name: l("Notification preference keys"),
      description: l("Which preference key each kind of notification is filtered by.")
    )
  end
end
