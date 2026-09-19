defmodule Bonfire.Notify.Content do
  @moduledoc """
  What a notification says: one activity turned into the fields a channel puts on the wire.

  Assembled once per activity in the fan-out job, in whichever languages its recipients read, and each delivery job carries the finished payload. That is the shape `ActivityPub.Federator.APPublisher` uses for outgoing federation, where one `publish` prepares the payload and each `publish_one` only sends it, and it is here for the same reason: what a notification says is the same for everyone who gets it, so loading and preloading the activity once per delivery would pay N times for one piece of work.

  Per-verb delivery data (whether the body may be shown, how long the push is worth keeping, how urgent it is, what it collapses with) is a config map keyed by verb slug, so a verb's behaviour is declared rather than coded. A verb declared `preview: false` gives who it is from and nothing of what it says, which is how a private message reaches a push service without its text.

  Describing the activity itself is not done here: who did what, what it said, where it points and a picture of whoever did it all come from `Bonfire.Social.Activities.describe/1`, which the in-app flash uses too, so a flash and a push say the same thing about the same activity. What is left here is what is genuinely about delivering it: the per-verb rules above, shortening the body to what a payload will take, and which id a client should collapse on.
  """
  use Bonfire.Common.Utils
  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Common.Text

  @doc """
  What to say and how to send it, as `%{content:, opts:}`.

  Both at once because both turn on the verb, and resolving it twice would read the same config and ask the same question twice. `content` is what a client shows: title, body, icon, url, `tag` (what it collapses on, so a burst about one object replaces itself rather than stacking), verb and activity id. `opts` is what a push transport takes: `ttl` in seconds, so a mention is still worth arriving tomorrow and a like is not, `urgency`, and `topic`, which lets the push service replace an undelivered push about the same thing rather than queue another.

  Says it in whatever language the process locale is set to, which is how one activity is assembled once per locale its recipients read rather than once per recipient.
  """
  def for_delivery(activity) do
    activity = preloaded(activity)
    object = e(activity, :object, nil)
    verb = verb_of(activity, object)
    collapse_id = collapse_id(activity, verb)
    preview? = metadata(verb, :preview, true) != false

    # who did what, what it said, where it points: all of that is about the data model, so it is asked for rather than worked out again here, and a flash and a push then say the same thing about the same activity
    described =
      maybe_apply(Bonfire.Social.Activities, :describe, [activity], fallback_return: %{})

    %{
      content: %{
        title:
          if(preview?,
            do: e(described, :title, nil),
            else: private_phrase(subject_name(e(activity, :subject, nil)), verb)
          ),
        body: if(preview?, do: shortened(e(described, :body, nil))),
        icon: e(described, :icon, nil),
        url: e(described, :url, nil),
        tag: collapse_id,
        verb: verb,
        activity_id: uid(activity),
        # what language this was assembled in, read from the locale rather than passed in, since that is what the wording above actually came out of. Its id rather than the whole CLDR tag, since this travels through a job's JSON and what a client wants is `en`. Mastodon's payload carries it
        locale: Bonfire.Common.Localise.get_locale_id()
      },
      opts: [
        ttl: metadata(verb, :ttl, default_ttl()),
        urgency: metadata(verb, :urgency, :normal),
        topic: collapse_id
      ]
    }
    |> debug("assembled a notification")
  end

  # an activity arrives in two states: loaded by id in the fan-out job, or already whole from a caller that had it in memory. Nothing is re-fetched for the second, since a loaded assoc is left alone.
  # `prune: true` because what an activity is about varies by verb (a post, a person followed, an edge), and one shape that doesn't fit the list would otherwise raise and take every notification in the batch with it
  defp preloaded(activity), do: repo().maybe_preload(activity, preloads(), prune: true)

  defp preloads do
    Config.get(
      [__MODULE__, :preloads],
      [
        :verb,
        :replied,
        subject: [:character, profile: :icon],
        object: [:post_content]
      ],
      name: l("Notification content preloads"),
      description: l("What to load about an activity in order to say what a notification says.")
    )
  end

  # a direct message stores the verb `:create` like any other post, so what it is gets decided by what it is about. Config rather than code, since which object types mean which verb is data, and Phase 1's recipient-relative verb answers the same question for every surface at once
  defp verb_of(activity, object) do
    # `bonfire_notify` doesn't depend on `bonfire_social`, so ask rather than call: with no social there are no activities to deliver anyway
    verb = maybe_apply(Bonfire.Social.Activities, :verb_slug, [activity], fallback_return: nil)

    Map.get(verbs_for_object_types(), Types.object_type(object), verb)
  end

  # what a notification says when its content must not leave the instance
  defp private_phrase(name, :message), do: l("%{name} sent you a message", name: name)
  defp private_phrase(name, _verb), do: l("%{name} notified you", name: name)

  defp subject_name(subject) do
    e(subject, :profile, :name, nil) || e(subject, :character, :username, nil) || l("Someone")
  end

  # a push payload has a size limit and the body is the part that grows, which is why shortening is ours rather than the describing function's
  defp shortened(nil), do: nil
  defp shortened(body), do: Text.truncate(body, max_body_length())

  # what a push replaces: the object it is about, or the whole conversation for a message, so a burst in one thread is one banner
  defp collapse_id(activity, verb) do
    case metadata(verb, :collapse, :object) do
      :thread ->
        e(activity, :replied, :thread_id, nil) || uid(e(activity, :object, nil))

      _ ->
        uid(e(activity, :object, nil)) || uid(activity)
    end
  end

  defp metadata(verb, key, default) do
    verbs()
    |> Map.get(verb, %{})
    |> Map.get(key, default)
  end

  defp verbs_for_object_types do
    Config.get([__MODULE__, :verbs_for_object_types], %{},
      name: l("What kind of notification each object type is"),
      description:
        l(
          "Object types whose notifications are treated as a different verb than the one stored, such as a direct message stored as a post."
        )
    )
  end

  defp verbs do
    Config.get([__MODULE__, :verbs], %{},
      name: l("Notification delivery data per verb"),
      description:
        l(
          "Whether each kind of notification may show its content, how long it stays worth delivering, how urgent it is, and what it collapses with."
        )
    )
  end

  defp default_ttl do
    Config.get([__MODULE__, :default_ttl], 86_400,
      name: l("Default push lifetime"),
      description:
        l("How long, in seconds, a push service should keep trying to reach an offline device.")
    )
  end

  defp max_body_length do
    Config.get([__MODULE__, :max_body_length], 200,
      name: l("Longest notification body"),
      description: l("How much of a notification's content to include, in characters.")
    )
  end
end
