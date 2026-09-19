defmodule Bonfire.Notify.API.MastoPushPayloadTest do
  @moduledoc """
  What each subscription is actually sent, when one activity reaches a Mastodon client and a client of ours.

  A Mastodon client cannot read the payload our service worker reads, so the shape is chosen per target at delivery rather than once per notification. That is why a delivery job carries what the notification says and not finished bytes. Mastodon's shape is flat and carries the access token, because a client is only told that something happened and then fetches the notification itself.

  The subscriptions here are made through the real `POST /api/v1/push/subscription`, since what marks one as a Mastodon client's is that endpoint recording it, and a hand-built row would prove nothing about the path that matters.
  """
  use Bonfire.Notify.ConnCase, async: false

  use Bonfire.Common.E

  alias Bonfire.Notify.PushDevice
  alias Bonfire.Notify.UserPushSubscription
  alias Bonfire.Notify.WebPush
  alias Bonfire.Notify.Worker

  import Bonfire.Common.Config, only: [repo: 0]

  @moduletag :masto_api

  setup do
    configure_web_push()

    # the two recipients, and somebody else's post for them to be notified about
    alice = fake_user!()
    bob = fake_user!()

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: fake_user!(),
        post_attrs: %{post_content: %{html_body: "something worth telling people about"}},
        boundary: "public"
      )

    {:ok, alice: alice, bob: bob, post: post}
  end

  # subscribes a browser the way our own app does
  defp subscribe_ours(user, endpoint) do
    {:ok, subscription} = WebPush.subscribe(user.id, valid_push_subscription_map(endpoint))
    subscription
  end

  # subscribes the way a Mastodon client does, through its own endpoint, so the row carries what that path records
  defp subscribe_masto(user, endpoint, alerts \\ nil) do
    data = if alerts, do: %{"alerts" => alerts}, else: %{}

    response =
      masto_authenticated_conn(user)
      |> post("/api/v1/push/subscription", %{
        "subscription" => valid_push_subscription_map(endpoint),
        "data" => data
      })
      |> json_response(200)

    assert response["endpoint"] == endpoint

    repo().get!(PushDevice, response["id"])
  end

  defp fan_out(post, users) do
    assert :ok =
             Worker.perform(%Oban.Job{
               args: %{
                 "op" => "fan_out",
                 "activity_id" => post.id,
                 "recipients" =>
                   Enum.map(users, &%{"user_id" => &1.id, "feed" => "notifications"}),
                 "feed_ids" => []
               }
             })

    Oban.Testing.all_enqueued(Bonfire.Common.Repo, worker: Worker)
    |> Enum.filter(&(e(&1, :args, "op", nil) == "deliver"))
  end

  defp deliver(job), do: Worker.perform(%Oban.Job{args: job.args, inserted_at: job.inserted_at})

  test "a Mastodon subscription is a web push device with its own provider", %{alice: alice} do
    device = subscribe_masto(alice, "https://push.bonfire.local/masto-client")

    assert device.provider == :web_masto,
           "the endpoint records what will read it, since a payload's shape is decided at delivery"

    assert device.auth_key, "it is still Web Push, so it still carries the browser's keys"

    assert [subscription] = WebPush.list_subscriptions(alice.id)

    assert subscription.access_token_id,
           "the payload has to carry the token it was authorised with"

    assert [%{target_id: target_id}] = WebPush.targets([alice.id], :create),
           "the web channel delivers to it, since it is reached in exactly the same way"

    assert target_id == device.id

    assert WebPush.targets([alice.id], :pin) == [],
           "a verb Mastodon has no name for cannot be described to it, so it is not a target for one"
  end

  test "our own client subscribes through a path that says so", %{alice: alice} do
    # the same controller and action as the Mastodon endpoint, on a path that declares whose client is asking: what a subscription needs is identical, and only the shape of payload its reader can understand differs. This is how the service worker re-registers a rotated endpoint
    response =
      conn(user: alice, account: alice.account)
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1-bonfire/push/subscription", %{
        "subscription" => valid_push_subscription_map("https://push.bonfire.local/our-sw")
      })
      |> json_response(200)

    device = repo().get!(PushDevice, response["id"])

    assert device.provider == :web,
           "marking it as a Mastodon client's would send it a shape it cannot read"

    assert [subscription] = WebPush.list_subscriptions(alice.id)

    refute subscription.access_token_id,
           "there is no authorisation to record, and Mastodon's payload is the only thing that needs one"
  end

  test "a client of ours holding a token is still a client of ours", %{alice: alice} do
    # the reason the path is explicit rather than inferred from the authentication: one of our own clients may well authorise with OAuth one day, and inferring would then send it Mastodon's shape
    response =
      masto_authenticated_conn(alice)
      |> post("/api/v1-bonfire/push/subscription", %{
        "subscription" =>
          valid_push_subscription_map("https://push.bonfire.local/ours-with-token")
      })
      |> json_response(200)

    assert repo().get!(PushDevice, response["id"]).provider == :web
  end

  test "one activity reaches both, each in the shape its client can read", %{
    alice: alice,
    bob: bob,
    post: post
  } do
    ours = subscribe_ours(bob, "https://push.bonfire.local/our-app")
    masto = subscribe_masto(alice, "https://push.bonfire.local/masto-app")

    jobs = fan_out(post, [alice, bob])
    assert length(jobs) == 2

    for job <- jobs, do: assert(:ok = deliver(job))

    payloads =
      for _ <- 1..2 do
        assert_receive {:web_push_sent, subscription, payload, _opts}
        {subscription.endpoint, Jason.decode!(payload)}
      end
      |> Map.new()

    theirs = payloads["https://push.bonfire.local/masto-app"]
    mine = payloads["https://push.bonfire.local/our-app"]

    # Mastodon's shape: flat, and carrying the token so the client can fetch the notification itself
    assert theirs["access_token"]
    assert theirs["notification_id"] == post.id
    assert theirs["notification_type"] == "mention"
    assert theirs["title"]
    assert theirs["preferred_locale"]
    refute theirs["data"], "Mastodon's payload is flat, so nothing is nested under data"

    # ours: what the service worker reads, with the link to open nested under data
    assert mine["data"]["url"]
    assert mine["data"]["activity_id"] == post.id
    refute mine["access_token"], "only a Mastodon client is sent a token"

    assert ours.push_device_id != masto.id, "two clients, two endpoints, two devices"
  end

  test "a verb Mastodon has no name for reaches our client and not theirs", %{
    alice: alice,
    bob: bob,
    post: post
  } do
    subscribe_ours(bob, "https://push.bonfire.local/our-app")
    subscribe_masto(alice, "https://push.bonfire.local/masto-app")

    # what Mastodon calls each of our verbs is a config table, so a verb missing from it is one Mastodon has no name for: its payload could not say which `notification_type` it is, and a client has no way to render it
    Process.put([:bonfire_notify, Bonfire.Notify.API.MastoPushAdapter, :alert_keys], %{})

    jobs = fan_out(post, [alice, bob])

    assert [job] = jobs,
           "with no Mastodon name for this verb, only our own client is worth a delivery"

    assert e(job, :args, "user_id", nil) == bob.id
  end

  test "a revoked authorisation stops its pushes, with nothing wired to the revoke", %{
    alice: alice,
    post: post
  } do
    subscribe_masto(alice, "https://push.bonfire.local/revoked")

    assert [subscription] = WebPush.list_subscriptions(alice.id)

    # the authorisation goes away, which is all it takes: the token is looked up at delivery rather than stored
    assert {:ok, _} =
             Bonfire.OpenID.Provider.Tokens.invalidate_for_user(
               alice.id,
               subscription.access_token_id
             )

    assert [job] = fan_out(post, [alice])

    assert {:cancel, _} = deliver(job),
           "a payload it could not read is nothing to send, and nothing to retry either"

    refute_receive {:web_push_sent, _, _, _}

    assert [_still_there] = repo().many(UserPushSubscription),
           "the subscription stays: deleting it on revoke would be bookkeeping, not the mechanism"
  end
end
