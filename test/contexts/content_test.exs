defmodule Bonfire.Notify.ContentTest do
  @moduledoc """
  What a notification says, and how it is sent.

  The content is what a client shows, so it names who it is from, says what happened, and points at the thing itself. A direct message is the exception: it says who wrote to you and nothing of what they said, because a push payload passes through a service we don't run and a mail server we don't
  either.

  The sending options come from the same verb, so a mention is still worth delivering tomorrow while a like is not, and a burst about one object collapses into one banner rather than a pile.
  """
  use Bonfire.Notify.DataCase, async: false

  use Bonfire.Common.E

  alias Bonfire.Notify.Content

  setup do
    alice = fake_user!()
    {:ok, alice: alice}
  end

  # as the fan-out job has it: read by id, so whatever it needs it has to load itself
  defp activity_of(object) do
    assert {:ok, activity} =
             Bonfire.Social.Activities.get(Bonfire.Common.Types.uid(object),
               skip_boundary_check: true
             )

    activity
  end

  # as a caller running the fan-out inline has it: whole already, straight off the publish
  defp activity_in_memory(object), do: e(object, :activity, nil)

  defp post!(user, html_body) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: html_body}},
        boundary: "public"
      )

    post
  end

  test "a post says who it is from, what it says, and where to find it", %{alice: alice} do
    post = post!(alice, "the whole point of the notification")

    assert %{content: content, opts: opts} = Content.for_delivery(activity_of(post))

    # who did what, from the same description the in-app flash uses. The verb's wording comes from the verb registry, so "created" reads clumsily until Phase 1 gives notifications their own phrasing: fixing it there fixes the flash and the push together, which is the point of sharing this
    assert content.title =~ e(alice, :profile, :name, nil) ||
             content.title =~ e(alice, :character, :username, nil)

    assert content.body =~ "the whole point of the notification"
    assert content.url
    assert content.activity_id == post.id

    assert content.tag == post.id,
           "a client collapses on the object, so a burst about one post replaces itself"

    assert opts[:topic] == content.tag
    assert opts[:ttl]
    assert opts[:urgency]
  end

  test "says the same thing whether the activity arrived loaded or not", %{alice: alice} do
    post = post!(alice, "the same words either way")

    # the two paths into a fan-out differ in exactly this: the job reads the activity by id, a caller running it inline already has it whole. Only one of them has anything to load, and both have to end up saying the same thing
    from_job = Content.for_delivery(activity_of(post))
    from_caller = Content.for_delivery(activity_in_memory(post))

    assert from_job.content == from_caller.content
    assert from_job.opts == from_caller.opts

    assert from_job.content.body =~ "the same words either way"
  end

  test "a body longer than the limit is cut to it", %{alice: alice} do
    post = post!(alice, String.duplicate("a very long message. ", 40))

    assert %{content: %{body: body}} = Content.for_delivery(activity_of(post))

    assert String.length(body) <= 210,
           "a push payload has a size limit, and the body is the part that grows"
  end

  test "a direct message says who wrote, and nothing of what they wrote", %{alice: alice} do
    bob = fake_user!()

    assert {:ok, message} =
             Bonfire.Messages.send(
               alice,
               %{post_content: %{html_body: "the secret is the badger"}},
               [bob]
             )

    assert %{content: content, opts: opts} = Content.for_delivery(activity_of(message))

    refute content.body,
           "a private message's text must not reach a push service or a mail server"

    assert content.title =~ "message",
           "it still has to say what arrived, or the notification is useless"

    refute content.title =~ "badger"

    assert content.verb == :message,
           "a message is stored with the verb :create, so what it is comes from what it is about"

    assert opts[:urgency] == :high
  end

  test "a like is worth less of a push service's patience than a mention", %{alice: alice} do
    post = post!(alice, "something to react to")
    bob = fake_user!()

    assert {:ok, like} = Bonfire.Social.Likes.like(bob, post)

    assert %{opts: like_opts} = Content.for_delivery(activity_of(like))
    assert %{opts: post_opts} = Content.for_delivery(activity_of(post))

    assert like_opts[:ttl] < post_opts[:ttl]
    assert like_opts[:urgency] == :low
  end

  test "an activity of a verb nothing is declared for still renders", %{alice: alice} do
    post = post!(alice, "a verb with no delivery data of its own")

    # a verb the config says nothing about must deliver on defaults rather than crash a job
    Process.put([:bonfire_notify, Bonfire.Notify.Content, :verbs], %{})

    assert %{content: content, opts: opts} = Content.for_delivery(activity_of(post))

    assert content.body =~ "a verb with no delivery data"
    assert opts[:ttl]
    assert opts[:urgency] == :normal
  end
end
