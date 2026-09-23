defmodule Bonfire.Notify.Channel do
  @moduledoc """
  What a delivery channel has to be able to do, and which ones this instance has.

  A channel knows three things nobody else should: where a person can be reached on it, how to put a notification's content on the wire, and what to make of the answer. Everything upstream of that (who is notified, whether they want it, what it says) is the same for every channel, which is what keeps adding one a config entry rather than a new branch in the fan-out.

  The registry is a keyword list in config, in display order, so a channel an instance hasn't configured simply isn't in `configured/0` and the fan-out writes no jobs for it.
  """
  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  use Bonfire.Common.E
  import Untangle

  @typedoc "A device or address to deliver to, as the channel's own row"
  @type target :: struct()

  @typedoc "What one delivery attempt means for the job that made it"
  @type result :: :ok | {:error, term()} | {:cancel, term()} | {:snooze, pos_integer()}

  @typedoc "What to say: the fields to deliver, or a payload that was serialised already"
  @type content :: map() | binary()

  @doc "Whether this instance can send on this channel at all (keys present, adapter loaded)."
  @callback configured?() :: boolean()

  @doc """
  Where these people can be reached on this channel for this kind of notification, as
  `[%{user_id:, target_id:}]`.

  Takes the whole batch and answers in one query: the fan-out asks once per channel however many
  recipients an activity has.

  The verb comes in because a target can carry switches of its own, which only it knows the shape of: a client that asked not to be told about this kind, or a subscription set not to be pushed to at all. Those can only narrow what the person's settings already allow, and a target that says nothing is left alone rather than given a default.
  """
  @callback targets([binary()], atom() | nil) :: [%{user_id: binary(), target_id: binary()}]

  @doc """
  Re-reads one target at delivery time, scoped to the person it was meant for.

  Scoped rather than by id alone, because an endpoint can rotate or move to another account on a shared browser between fan-out and delivery, and delivering to whoever holds it now would send someone else's notification. Not found means don't deliver, so this doubles as the inactive check.
  """
  @callback target(binary(), binary()) :: {:ok, target()} | {:error, :inactive}

  @doc """
  Puts one notification's content on the wire and says what the job should do next.

  Recording what happened to the target row (success, inactive, last error) belongs here too, since
  the shape of that row is the channel's own.

  Content is the fields to deliver (title, body, icon, url, tag, verb, activity id), or an already-serialised payload from the older batch path.
  """
  @callback deliver(target(), content(), keyword()) :: result()

  @doc """
  Whether to deliver there and then rather than queue a job per target.

  For a channel where late is worthless and there is nothing to retry, like showing a notification to whoever is connected (`Bonfire.Notify.Live`). Defaults to false.
  """
  @callback immediate?() :: boolean()

  @optional_callbacks immediate?: 0

  @doc "Whether this channel's adapter delivers immediately (`c:immediate?/0`), false for one that doesn't say."
  def immediate?(adapter) when is_atom(adapter) do
    function_exported?(adapter, :immediate?, 0) and adapter.immediate?() == true
  end

  def immediate?(_adapter), do: false

  @doc """
  The channels this instance can actually send on, as `[{key, module}]` in declared order.

  Used by the fan-out to decide which targets exist, and by the preferences UI to decide which columns to show, so a channel is switched on in exactly one place.
  """
  def configured do
    Enum.filter(channels(), fn {key, module} ->
      case Bonfire.Common.Extend.maybe_module(module) do
        nil ->
          debug(key, "channel module is not available, so not offering it")
          false

        module ->
          module.configured?()
      end
    end)
  end

  @doc """
  The payload both push transports take, as a map, built from a notification's content.

  One shape rather than one per channel: a web push ends at the service worker and a native push at the OS notification centre, and both read the same keys. It stays a map until an adapter hands bytes to its transport, so serialising happens once, at the wire, rather than in whichever module happened to own the formatter.
  """
  def push_payload(content) do
    # `ed` rather than `e`, because a delivery job's arguments are JSON and come back with string keys, which the macro would read as missing
    %{
      title: ed(content, :title, nil),
      body: ed(content, :body, nil),
      icon: ed(content, :icon, nil),
      tag: ed(content, :tag, nil),
      requireInteraction: ed(content, :require_interaction, false) || false,
      data: %{
        url: ed(content, :url, nil),
        verb: ed(content, :verb, nil),
        activity_id: ed(content, :activity_id, nil)
      }
    }
  end

  @doc """
  The bytes to send to one target, as the shape whatever is listening there can read.

  Chosen per target rather than per notification, which is why a delivery job carries the assembled content and not finished bytes: one activity can reach a client of ours and a Mastodon client, and those read different shapes. Assembling still happens once (the expensive part is loading and describing the activity); encoding is cheap and happens here, at the wire, where the target is in hand.

  A Mastodon subscription's payload is Mastodon's to define, so it is built by `Bonfire.Notify.API.MastoPushAdapter`, which is also the only module that may answer whether a target is one. Anything else gets the shape our own service worker and native app read.

  Answers `{:error, reason}` when a target needs a shape we cannot build for it, which a delivery must treat as nothing to send rather than falling back: our shape delivered to a Mastodon client is bytes it cannot read.
  """
  def payload_json(_target, content) when is_binary(content) do
    error(
      content,
      "A delivery carries a notification's content, not finished bytes, since what shape to send is the target's to decide"
    )
  end

  def payload_json(target, content) do
    if Bonfire.Notify.API.MastoPushAdapter.masto?(target) do
      with {:ok, payload} <- Bonfire.Notify.API.MastoPushAdapter.payload(target, content) do
        {:ok, Jason.encode!(payload)}
      end
    else
      {:ok, content |> push_payload() |> Jason.encode!()}
    end
  end

  @doc "The adapter for a channel key, or an error for one this instance doesn't declare."
  def adapter(key) when is_atom(key) do
    case Keyword.fetch(channels(), key) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_channel}
    end
  end

  def adapter(key) when is_binary(key) do
    # a job carries the key as a string, and an unknown one must not create an atom
    case Enum.find(channels(), fn {declared, _module} -> to_string(declared) == key end) do
      {_declared, module} -> {:ok, module}
      nil -> {:error, :unknown_channel}
    end
  end

  defp channels do
    Config.get([__MODULE__, :channels], [],
      name: l("Notification delivery channels"),
      description: l("Which channels notifications can be delivered on, in display order.")
    )
  end
end
