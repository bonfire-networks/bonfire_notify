defmodule Bonfire.Notify.VapidSubjectTest do
  @moduledoc """
  Who a web push says it is from.

  The VAPID `sub` claim is how a push service reaches whoever is sending (RFC 8292), so it has to name this instance. An operator who sets one keeps it; otherwise the instance's own URL is filled in once the endpoint config is loaded. Until 2026-09-19 the fallback was a hardcoded `https://bonfire.cafe`, so every instance that never set the env var named somebody else as its contact.
  """
  use Bonfire.Notify.DataCase, async: false

  setup do
    previous = Application.get_env(:ex_nudge, :vapid_subject)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ex_nudge, :vapid_subject)
        subject -> Application.put_env(:ex_nudge, :vapid_subject, subject)
      end
    end)

    :ok
  end

  test "with none set, this instance names itself" do
    Application.delete_env(:ex_nudge, :vapid_subject)

    Bonfire.Notify.maybe_set_vapid_subject()

    subject = Application.get_env(:ex_nudge, :vapid_subject)

    assert subject == Bonfire.Common.URIs.base_url()
    assert subject =~ "http", "a push service has to be able to reach it"
  end

  test "an operator's own subject is left alone" do
    # what someone sets via WEB_PUSH_SUBJECT, usually a mailto: they actually read
    Application.put_env(:ex_nudge, :vapid_subject, "mailto:admin@example.local")

    Bonfire.Notify.maybe_set_vapid_subject()

    assert Application.get_env(:ex_nudge, :vapid_subject) == "mailto:admin@example.local"
  end
end
