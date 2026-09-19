defmodule Bonfire.Notify.Recipients do
  @moduledoc """
  Who a notification is for: the people a fan-out job names, and by which of their feeds.

  The write path resolves its recipients while addressing an activity, so a job carries their ids
  (job args hold references, never structs or rendered content) and this only loads them back. Feed ids are carried too
  for the paths that never had people to begin with, a circle's notifications or the admin feeds, and
  are resolved the long way round, through `Character`.

  Which feed a recipient was reached by is kept alongside them, because `:inbox` means a DM and DMs
  are delivered differently (no body in the payload, the thread as the URL, higher urgency).
  Deriving that from the verb instead would rest on the inbox-is-DM-only convention rather than on
  what actually happened.
  """
  use Bonfire.Common.Repo
  use Bonfire.Common.E
  import Ecto.Query
  import Untangle

  alias Bonfire.Common.Types
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.Identity.User

  @doc """
  The recipients a fan-out job names, as `[{user, :notifications | :inbox}]`.

  `recipients` are what the write path already resolved (`[%{"user_id" => id, "feed" => "inbox"}]`),
  `feed_ids` are the feeds it didn't. Both in ONE query: people named by id and people found by
  feed differ only in how they were addressed, and a recipient reached both ways appears once, taking
  the class the job stated over the one the feed implies.

  Settings are loaded for the user AND their account, since a preference can be set at either scope
  and reading one without the other silently ignores account-level choices.
  """
  def for_job(recipients, feed_ids \\ [], opts \\ [])

  def for_job([], [], _opts), do: []

  def for_job(recipients, feed_ids, opts) do
    feed_ids = List.wrap(feed_ids)
    stated = stated_classes(recipients)
    user_ids = Map.keys(stated)

    exclude =
      opts[:exclude]
      |> List.wrap()
      |> Enum.map(&Types.uid/1)
      |> Enum.reject(&is_nil/1)

    from(u in User,
      join: c in Character,
      on: c.id == u.id,
      where:
        u.id in ^user_ids or c.notifications_id in ^feed_ids or
          c.inbox_id in ^feed_ids,
      where: u.id not in ^exclude,
      select: {u, c.inbox_id}
    )
    # join-preloaded rather than fetched and then preloaded: these are all one-to-one, so it all comes back with the people. The account's settings need a binding prefix, or they collide with the user's own. `character: [:peered]` is what makes these subjects classifiable by locality, without which a boundary check gives them no locality circle (and says so loudly in test)
    |> proload([
      :settings,
      character: [:peered],
      accounted: [account: {"account_", [:settings]}]
    ])
    |> repo().many()
    |> Enum.map(fn {user, inbox_id} ->
      {user, stated[user.id] || if(inbox_id in feed_ids, do: :inbox, else: :notifications)}
    end)
    |> debug("recipients to notify")
  end

  defp stated_classes(recipients) do
    recipients
    |> List.wrap()
    |> Enum.map(&stated_class/1)
    |> Enum.reject(fn {user_id, _feed} -> is_nil(user_id) end)
    |> Map.new()
  end

  # a job carries recipients as maps with string keys, while a caller running the fan-out inline still has the `{character, feed}` pairs the write path resolved while addressing the activity
  defp stated_class({character, feed}), do: {Types.uid(character), feed_class(feed)}

  defp stated_class(recipient) do
    {Types.uid(e(recipient, "user_id", nil) || e(recipient, :user_id, nil)),
     feed_class(e(recipient, "feed", nil) || e(recipient, :feed, nil))}
  end

  defp feed_class(nil), do: :notifications
  defp feed_class(feed) when is_atom(feed), do: feed
  defp feed_class(feed), do: Types.maybe_to_atom!(feed) || :notifications
end
