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

  Categories rather than verbs because a category is what a person is shown and switches: the same key that decides whether a kind appears in their notifications feed (`[:notifications, :centre, <category>]`) decides whether it is pushed, so one row in the UI is one setting per channel.

  A category is not a verb and is not derivable from one: which grouping a notification belongs to can depend on the object as well (a direct message is a `create` of a `Message`, which is why `Bonfire.Notify.Content` overrides the verb by object type) and on the recipient's own relation to it (a mention is a tag pointing at *them*). So `Bonfire.Social.Notifications` is asked rather than copied here, since it owns both what each category covers and how exact that answer is, and this reads whatever it is told. Anything no category covers falls to the catch-all rather than getting a key of its own.

  A person who has never touched these switches still has their old coarse ones honoured: those hold one key per group of verbs (`[:push_notifications, :likes]` and friends), so they are read as a fallback rather than migrated, and a new choice takes precedence over the old one.
  """
  def enabled?(user, verb, channel \\ :push) do
    category_of(verb)
    |> chosen(user, channel)
    |> case do
      nil ->
        case setting(user, [:notifications, channel, :other]) do
          nil -> coarse_enabled?(user, verb, channel)
          catch_all -> catch_all != false
        end

      chosen ->
        chosen != false
    end
    |> debug("deliver #{inspect(verb)} on #{inspect(channel)}?")
  end

  # a verb no category covers has no switch of its own, and falls to the catch-all rather than inventing a key: the key space is categories, and a bare verb in it could collide with a category of the same name meaning something else (the `mention` category is the `create` verb, while `mention` is also a verb in its own right)
  defp chosen(nil, _user, _channel), do: nil
  defp chosen(category, user, channel), do: setting(user, [:notifications, channel, category])

  # asked rather than copied, since `bonfire_social` owns the categories a person is shown switches for. With no social there are no activities to deliver anyway
  defp category_of(verb) do
    maybe_apply(
      Bonfire.Social.Notifications,
      :category_for_activity_type,
      [verb],
      fallback_return: nil
    )
  end

  defp setting(user, keys), do: Settings.get(keys, nil, context: user)

  # the keys today's UI writes, one per group of verbs, and only for push: native follows it and email has none of its own yet
  defp coarse_enabled?(user, verb, channel) when channel in [:push, :native_push, :web_push] do
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
