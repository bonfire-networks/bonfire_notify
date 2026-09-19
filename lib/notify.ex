defmodule Bonfire.Notify do
  @moduledoc """
  The extension itself: what it declares, and the VAPID keys web push needs.

  Sending is not here. Who to notify is `Bonfire.Notify.FanOut`, what a notification says is
  `Bonfire.Notify.Content`, where it goes is a `Bonfire.Notify.Channel`, and the deliveries are
  `Bonfire.Notify.Worker`'s.
  """

  use Application
  use Bonfire.Common.Utils
  import Untangle

  def start(_, _) do
    :telemetry.attach(
      "bonfire_notify_vapid_setup",
      [:settings, :load_config, :stop],
      fn _event, _measurements, _meta, _config ->
        :telemetry.detach("bonfire_notify_vapid_setup")
        Bonfire.Notify.maybe_generate_keys()
        Bonfire.Notify.maybe_set_vapid_subject()
      end,
      nil
    )

    Supervisor.start_link([], strategy: :one_for_one)
  end

  declare_extension(
    l("Notifications"),
    icon: "ph:device-mobile",
    description: l("Manage your notification settings and registered devices")
  )

  def enabled? do
    Application.get_env(:ex_nudge, :vapid_public_key) != nil and
      Application.get_env(:ex_nudge, :vapid_private_key) != nil
  end

  @doc """
  Names this instance as the sender of its web pushes, unless something already does.

  The VAPID `sub` claim is how a push service reaches whoever is sending (RFC 8292), so it has to be this instance: an operator who sets `WEB_PUSH_SUBJECT` (usually a `mailto:`) is kept, and otherwise the instance's own URL is used. Runs once the endpoint config is loaded, since that is when the URL is knowable.

  Not persisted, unlike the keys: it is derived from the instance's URL, so a stored copy would go stale the moment a domain changed, while working it out each boot fixes itself.
  """
  def maybe_set_vapid_subject do
    if !Application.get_env(:ex_nudge, :vapid_subject) do
      case Bonfire.Common.URIs.base_url() do
        url when is_binary(url) and url != "" ->
          info(url, "Naming this instance as the sender of its web push notifications")
          Bonfire.Common.Config.put([:ex_nudge, :vapid_subject], url)

        other ->
          warn(
            other,
            "Could not work out this instance's URL, so web pushes will carry no sender. Set WEB_PUSH_SUBJECT"
          )
      end
    end
  end

  @doc """
  Generates VAPID keys for web push notifications if none are configured.

  Called after `Bonfire.Common.Settings.LoadInstanceConfig` completes (via telemetry hook),
  so DB-stored keys are already loaded into OTP config before we check.
  Generated keys are persisted to instance settings so they survive restarts.
  """
  def maybe_generate_keys do
    if !Bonfire.Notify.enabled?() do
      info("Generating VAPID keys for web push notifications")
      keys = ExNudge.VAPID.generate_vapid_keys()

      # Persists to DB and also updates OTP config in-process via Config.put_tree,
      # so keys are immediately available via Application.get_env(:ex_nudge, ...)
      Bonfire.Common.Settings.put([:ex_nudge, :vapid_public_key], keys.public_key,
        scope: :instance,
        skip_boundary_check: true
      )

      Bonfire.Common.Settings.put([:ex_nudge, :vapid_private_key], keys.private_key,
        scope: :instance,
        skip_boundary_check: true
      )
    end
  end
end
