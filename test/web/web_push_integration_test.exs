defmodule Bonfire.Notify.WebPushIntegrationTest do
  @moduledoc """
  One delivery through the real ExNudge, with no mock in the way.

  Everything about what each answer means is pinned in `test/channels/web_push_channel_test.exs` against the mock, which is where the response mapping belongs. What cannot be checked there is that we are calling the library correctly at all: that a subscription of ours converts into something ExNudge accepts, that a failure comes back in a shape we understand rather than raising, and that a failed send leaves the subscription alone rather than deactivating it.

  The endpoint is deliberately unreachable, so the send is expected to fail. What matters is how.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.Repo

  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.WebPush

  test "a real send to an unreachable endpoint fails in a shape we handle" do
    user = fake_user!()

    {:ok, link} =
      WebPush.subscribe(
        user.id,
        valid_push_subscription_map("https://push.bonfire.local/unreachable")
      )

    assert {:ok, target} = WebPush.target(link.push_device_id, user.id)

    result = WebPush.deliver(target, %{title: "Real test", body: "Testing real ExNudge"})

    # either the push service refused it or we never got that far (no usable VAPID keys here): both are errors we map rather than exceptions we leak
    assert match?({:error, _}, result) or match?({:cancel, _}, result),
           "got #{inspect(result)}"

    recorded = repo().get!(PushDevice, link.push_device_id)

    assert recorded.last_status == :error
    assert recorded.last_error

    assert recorded.active == true,
           "a failed send is not a gone endpoint, so the subscription stays usable"
  end
end
