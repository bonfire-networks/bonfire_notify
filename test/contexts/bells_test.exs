defmodule Bonfire.Notify.BellsTest do
  @moduledoc """
  Bells: asking to be notified about everything a person posts.

  Off unless the person enables it, never by following alone. With it on, the author's new posts reach the reader's notifications as the post's own activity, through the same fan-out as a mention. A bell on a person covers their new posts, not their replies, which belong to the threads they are in.
  """
  use Bonfire.Notify.DataCase, async: true

  alias Bonfire.Notify.Bells
  alias Bonfire.Social.Graph.Follows

  setup do
    {:ok, author: fake_user!("Bell Author"), reader: fake_user!()}
  end

  defp publish(author, text, opts \\ []) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: Map.merge(%{post_content: %{html_body: text}}, Map.new(opts)),
        boundary: "public"
      )

    post
  end

  defp notified?(reader, post),
    do: Bonfire.Social.FeedLoader.feed_contains?(:notifications, post, current_user: reader)

  test "with the bell on, a followed author's new post is in the reader's notifications", %{
    author: author,
    reader: reader
  } do
    {:ok, _} = Follows.follow(reader, author)
    assert {:ok, _} = Bells.enable(reader, author)

    assert notified?(reader, publish(author, "something new from the author"))
  end

  test "following alone notifies of nothing", %{author: author, reader: reader} do
    {:ok, _} = Follows.follow(reader, author)

    refute notified?(reader, publish(author, "something new from the author"))
  end

  test "enabling it twice keeps one bell, and disabling it stops the notifications", %{
    author: author,
    reader: reader
  } do
    {:ok, _} = Follows.follow(reader, author)
    assert {:ok, _} = Bells.enable(reader, author)
    assert {:ok, _} = Bells.enable(reader, author)
    assert Bells.enabled?(reader, author)

    Bells.disable(reader, author)
    refute Bells.enabled?(reader, author)

    refute notified?(reader, publish(author, "something new from the author"))
  end

  test "an author's reply does not reach the people with a bell on them", %{
    author: author,
    reader: reader
  } do
    {:ok, _} = Follows.follow(reader, author)
    {:ok, _} = Bells.enable(reader, author)

    root = publish(fake_user!(), "someone else's post")
    reply = publish(author, "the author replying", reply_to_id: root.id)

    # the positive first: the author's own new posts do reach them
    assert notified?(reader, publish(author, "a post of the author's own"))
    refute notified?(reader, reply)
  end

  describe "on a thread" do
    # no follow needed: a bell on a thread's first post covers the replies in it
    test "with the bell on, a reply in the thread is in the reader's notifications", %{
      author: author,
      reader: reader
    } do
      root = publish(author, "a thread worth following")
      assert {:ok, _} = Bells.enable(reader, root)

      reply = publish(fake_user!(), "a reply in it", reply_to_id: root.id)

      assert notified?(reader, reply)
    end

    test "a reply to a reply still counts, being in the same thread", %{
      author: author,
      reader: reader
    } do
      root = publish(author, "a thread worth following")
      {:ok, _} = Bells.enable(reader, root)

      first = publish(fake_user!(), "a first reply", reply_to_id: root.id)
      deeper = publish(fake_user!(), "a reply to the reply", reply_to_id: first.id)

      assert notified?(reader, deeper)
    end

    test "without the bell, replies in someone else's thread do not notify", %{
      author: author,
      reader: reader
    } do
      root = publish(author, "a thread")

      refute notified?(reader, publish(fake_user!(), "a reply in it", reply_to_id: root.id))
    end

    test "your own replies in a thread you have a bell on do not notify you", %{
      author: author,
      reader: reader
    } do
      root = publish(author, "a thread worth following")
      {:ok, _} = Bells.enable(reader, root)

      # the positive first: someone else's reply does
      assert notified?(reader, publish(fake_user!(), "someone's reply", reply_to_id: root.id))
      refute notified?(reader, publish(reader, "the reader's own reply", reply_to_id: root.id))
    end
  end

  describe "on a group" do
    # a public group whose posts anyone may read, so what is being tested is the bell and not the group's boundaries
    setup %{author: author} do
      group =
        Bonfire.Classify.Simulate.fake_group!(author, %{
          membership: "open",
          visibility: "global:discoverable"
        })

      {:ok, group: group}
    end

    # posts come from members, and the group's own boundaries decide who may read them, so both people here are members
    defp member(group, user \\ fake_user!()) do
      {:ok, _} = Bonfire.Classify.Categories.join_group(user, group)
      user
    end

    defp post_in(group, html),
      do: Bonfire.Classify.Simulate.fake_post_in_group!(member(group), group, html)

    test "with the bell on, a new post in the group is in the reader's notifications", %{
      group: group,
      reader: reader
    } do
      member(group, reader)
      assert {:ok, _} = Bells.enable(reader, group)

      assert notified?(reader, post_in(group, "<p>news for the group</p>"))
    end

    test "without the bell, a post in the group does not notify", %{group: group, reader: reader} do
      member(group, reader)

      refute notified?(reader, post_in(group, "<p>news for the group</p>"))
    end
  end

  test "unfollowing disables the bell", %{author: author, reader: reader} do
    {:ok, _} = Follows.follow(reader, author)
    {:ok, _} = Bells.enable(reader, author)
    assert Bells.enabled?(reader, author)

    Follows.unfollow(reader, author)

    refute Bells.enabled?(reader, author)
  end
end
