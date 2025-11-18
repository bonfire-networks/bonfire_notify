# Ensure the mock module is compiled
# Code.require_file("support/ex_nudge_mock.ex", __DIR__)

# Set test VAPID keys if none are configured
unless Application.get_env(:ex_nudge, :vapid_details) do
  # Generate test keys using ExNudge
  test_keys = ExNudge.generate_vapid_keys()

  Application.put_env(:ex_nudge, :vapid_details,
    vapid_subject: "mailto:test@example.com",
    vapid_public_key: test_keys.public_key,
    vapid_private_key: test_keys.private_key
  )
end

ExUnit.start(exclude: Bonfire.Common.RuntimeConfig.skip_test_tags())

Ecto.Adapters.SQL.Sandbox.mode(
  Bonfire.Common.Config.repo(),
  :manual
)
