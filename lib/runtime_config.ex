defmodule Bonfire.Notify.RuntimeConfig do
  @moduledoc "Config and helpers for this library"

  import Untangle
  require Bonfire.Common.Config
  use Bonfire.Common.Localise

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @yes? ~w(true yes 1)
  @no? ~w(false no none 0)

  def config do
    import Config

    # config :bonfire_notify,
    #   modularity: :disabled
    config :bonfire_notify, modularity: nil

    # how often the email digest goes out for anyone who has not chosen, `never` unless the env says otherwise, so nobody gets email they did not ask for. An admin can change it with the "Email digest" dropdown in instance settings
    config :bonfire, :notifications,
      email_digest:
        (case System.get_env("EMAIL_DIGEST_DEFAULT", "never") do
           frequency when frequency in ~w(daily weekly monthly) -> String.to_atom(frequency)
           _ -> :never
         end)

    # Which coarse preference key a verb is filtered by, until preferences become per-verb. Keys are verbs, values are the setting under `[:push_notifications, …]`; a verb that names none is not filtered at all
    config :bonfire_notify, Bonfire.Notify.Preferences,
      # which switch each delivery channel (`Bonfire.Notify.Channel`'s keys) follows. A person sees one Push switch per kind of notification, for every device, and a device they don't want pushed to at all has its own switch (`policy: "none"`). A Mastodon client narrows further with its own alerts
      channels: %{web_push: :push, native_push: :push, live: :push, email: :email},
      # the old UI's one email switch, by the category it covered, read until a new email choice is made for that category
      email_categories: %{
        mention: [:email_notifications, :reply_or_mentions],
        extra_replies: [:email_notifications, :reply_or_mentions]
      },
      # keyed by what `Bonfire.Social.Activities.experienced_as/2` answers, which is finer than the old switches were: asking to follow and asking to quote both fall to the one "follows" key somebody may have set, and writing a post falls in with replies and mentions, so an old choice keeps being honoured rather than being half-read
      push_categories: %{
        like: :likes,
        react: :likes,
        boost: :boosts,
        follow: :follows,
        request: :follows,
        follow_request: :follows,
        quote_request: :follows,
        message: :messages,
        create: :replies_and_mentions,
        write: :replies_and_mentions,
        reply: :replies_and_mentions,
        respond: :replies_and_mentions,
        mention: :replies_and_mentions
      }

    # How each kind of notification is delivered. `preview: false` sends who it is from without what it says, `ttl` is how many seconds a push service should keep trying an offline device, and `collapse: :thread` replaces a burst in one conversation with one banner
    config :bonfire_notify, Bonfire.Notify.Content,
      max_body_length: 200,
      default_ttl: 86_400,
      # what to load about an activity in order to say what its notification says: who it is from, what it is about, and which thread it belongs to
      preloads: [
        :verb,
        :replied,
        subject: [:character, profile: :icon],
        object: [:post_content]
      ],
      # a direct message is stored as a post with the verb `:create`, so what it is has to be read from what it is about
      verbs_for_object_types: %{Bonfire.Data.Social.Message => :message},
      verbs: %{
        message: %{preview: false, ttl: 86_400, urgency: :high, collapse: :thread},
        mention: %{ttl: 86_400, urgency: :high},
        request: %{ttl: 86_400, urgency: :high},
        flag: %{ttl: 86_400, urgency: :high},
        reply: %{ttl: 86_400, urgency: :normal},
        quote: %{ttl: 86_400, urgency: :normal},
        like: %{ttl: 3_600, urgency: :low},
        boost: %{ttl: 3_600, urgency: :low},
        vote: %{ttl: 3_600, urgency: :low}
      }

    # What each kind of notification is called in Mastodon's API, for the one place that translates: a client's `alerts` map is keyed by these, everything else here speaks Bonfire verbs. A verb absent from this map cannot be muted by a Mastodon client, since the client has no name for it
    config :bonfire_notify, Bonfire.Notify.API.MastoPushAdapter,
      alert_keys: %{
        # a post reaching your notifications addressed you, which is what Mastodon calls a mention. Our own taxonomy stores it as a `create` (`Bonfire.Social.Notifications`' `mention` category names `activity_types: [:create]`), so both spellings map here
        create: "mention",
        mention: "mention",
        reply: "mention",
        message: "mention",
        # an admin broadcast is a post, so this is what it is rather than a stand-in: Mastodon's `status` means "a new post you asked to hear about"
        broadcast: "status",
        # the ask, filed under the same switch as the quoting it asks for
        quote_request: "quote",
        like: "favourite",
        boost: "reblog",
        follow: "follow",
        request: "follow_request",
        quote: "quote",
        flag: "admin.report",
        vote: "poll",
        edit: "update"
      },
      # every type the API documents, because a response has to carry all of them and a client can only display the keys it is given. `docs.joinmastodon.org/methods/push/`, including `quote` and `quoted_update` from Mastodon 4.5
      response_types: [
        "mention",
        "status",
        "reblog",
        "follow",
        "follow_request",
        "favourite",
        "poll",
        "update",
        "quote",
        "quoted_update",
        "admin.sign_up",
        "admin.report"
      ]

    # One getting-started step, declared here because turning notifications on is this extension's feature. Its action is the card that asks this browser for permission rather than a link somewhere, since that flow needs the component that owns it, and the card renders nothing where the browser has already refused. The step is done once notifications reach this person on any device
    config :bonfire_ui_common, Bonfire.UI.Common.WidgetGettingStartedLive,
      actions_registry: [
        notifications: %{
          title: l("Turn on notifications"),
          rationale: l("So a reply or a message reaches you even when this tab isn't open."),
          cta_kind: :stateful_component,
          cta_component: Bonfire.Notify.Settings.PushNotificationsLive,
          cta_path: nil,
          needs: Bonfire.Notify.UserPushSubscription,
          done?: &Bonfire.Notify.UserPushSubscription.any_active?/1
        }
      ]

    # The channels a notification can be delivered on, in the order they appear to the user. A channel whose `configured?/0` is false is skipped, so an instance without VAPID keys or a native adapter simply has fewer of them
    config :bonfire_notify, Bonfire.Notify.Channel,
      channels: [
        web_push: Bonfire.Notify.WebPush,
        native_push: Bonfire.Notify.NativePush,
        # whoever is connected right now (an open page, the native app's SSE stream), which is what push falls back to
        live: Bonfire.Notify.Live,
        # a person's confirmed account address, for someone who asked to be emailed as things happen
        email: Bonfire.Notify.Email
      ],
      # how long to wait before retrying a delivery a push service rate-limited, since ExNudge doesn't surface the `Retry-After` header
      snooze_seconds: 60

    # The queue `Bonfire.Notify.Worker` runs in, declared here so an instance without this extension has no queue for it. Extension configs load before the flavour's Oban block (`config/runtime.exs`) and `Config` deep-merges keyword lists, so this is added to the flavour's queues rather than replacing them, and a flavour can still override the size by naming `notify:` itself
    config :bonfire, Oban,
      queues: [notify: String.to_integer(System.get_env("QUEUE_SIZE_NOTIFY", "2"))]

    # NOTE How many times a delivery job is worth retrying is read at compile time (`Application.compile_env` in `Bonfire.Notify.Worker`, whose default is the same 5), since that is when Oban takes a worker's defaults, so it cannot be set here: this runs at boot, after the release was compiled without it, and a release refuses to boot when a compile-time value differs at runtime ("aborting boot" in `Config.Provider`). To change it, set it in compile-time config (`config/bonfire_notify.exs`) and rebuild.
    # config :bonfire_notify, Bonfire.Notify.Worker, max_attempts: 5

    config :ex_nudge,
      vapid_public_key: System.get_env("WEB_PUSH_PUBLIC_KEY"),
      vapid_private_key: Bonfire.Common.EnvSecrets.env_or_file("WEB_PUSH_PRIVATE_KEY"),
      # who is sending, per RFC 8292: a push service uses it to reach whoever operates the instance. Left unset when no env var says otherwise, and `Bonfire.Notify.maybe_set_vapid_subject/0` fills in this instance's own URL once the endpoint is known. It used to default to `https://bonfire.cafe`, so every unconfigured instance was naming somebody else as its contact
      vapid_subject: System.get_env("WEB_PUSH_SUBJECT")
  end
end
