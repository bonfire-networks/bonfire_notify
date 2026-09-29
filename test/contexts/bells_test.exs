defmodule Bonfire.Notify.BellsTest do
  @moduledoc """
  Bells: asking to be notified about everything a person posts.

  Off unless the person enables it, never by following alone. With it on, the author's new posts reach the reader's notifications as the post's own activity, through the same fan-out as a mention. A bell on a person covers their new posts, not their replies, which belong to the threads they are in.
  """
  use Bonfire.Notify.DataCase, async: true
  use Bonfire.Common.E

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

  # a bell on any post covers the replies below it, however deep, so a branch of a thread can be followed on its own
  describe "on a comment" do
    test "with notifications on for it, a reply below it notifies, and a reply elsewhere in the thread doesn't",
         %{author: author, reader: reader} do
      root = publish(author, "a thread")
      comment = publish(fake_user!(), "a comment worth following", reply_to_id: root.id)
      {:ok, _} = Bells.enable(reader, comment)

      below = publish(fake_user!(), "answering the comment", reply_to_id: comment.id)
      deeper = publish(fake_user!(), "answering that", reply_to_id: below.id)
      elsewhere = publish(fake_user!(), "answering the thread", reply_to_id: root.id)

      assert notified?(reader, below)
      assert notified?(reader, deeper)
      refute notified?(reader, elsewhere)
    end
  end

  # what you write enables notifications of the replies below it, even when you're not mentioned, and you can turn that off for one post
  describe "your own posts" do
    test "a new post enables notifications of its replies", %{author: author} do
      post = publish(author, "my post")

      assert Bells.enabled?(author, post)
    end

    test "a comment enables notifications of its replies", %{author: author} do
      root = publish(fake_user!(), "someone else's thread")
      comment = publish(author, "my comment", reply_to_id: root.id)

      assert Bells.enabled?(author, comment)
    end

    test "a comment below a post you already get notifications for enables none, since that one covers it",
         %{author: author} do
      root = publish(author, "my thread")
      comment = publish(author, "my comment in it", reply_to_id: root.id)

      # the positive first: the thread's first post enabled them
      assert Bells.enabled?(author, root)
      refute Bells.enabled?(author, comment)
    end

    test "with the switch off, nothing is enabled", %{author: author} do
      author =
        Bonfire.Common.Utils.current_user(
          Bonfire.Common.Settings.put([:notifications, :notify_any_replies], false,
            current_user: author
          )
        )

      refute Bells.enabled?(author, publish(author, "my quiet post"))
    end

    test "a reply further down notifies whoever wrote a post above it", %{author: author} do
      root = publish(author, "my thread")
      first = publish(fake_user!(), "a first reply", reply_to_id: root.id)
      deeper = publish(fake_user!(), "a reply to the reply", reply_to_id: first.id)

      assert notified?(author, deeper)
    end

    test "turning a post's notifications off stops even its direct replies", %{author: author} do
      # the positive first: with them on, a direct reply notifies
      followed = publish(author, "a post I still follow")
      assert notified?(author, publish(fake_user!(), "a reply", reply_to_id: followed.id))

      silenced = publish(author, "a post I stopped following")
      Bells.disable(author, silenced)

      refute notified?(author, publish(fake_user!(), "a reply", reply_to_id: silenced.id))
    end

    test "who follows a discussion by a post they wrote is told apart from who only follows it",
         %{author: author, reader: reader} do
      root = publish(author, "my thread")
      {:ok, _} = Bells.enable(reader, root)

      subscribers = Bells.subscribers([root.id], fake_user!(), authorship: true)

      assert {_, true} = Enum.find(subscribers, fn {s, _} -> s.id == author.id end)
      assert {_, false} = Enum.find(subscribers, fn {s, _} -> s.id == reader.id end)
    end

    test "a reply that mentions you notifies you, even with the post's notifications off", %{
      author: author
    } do
      post = publish(author, "a post I stopped following")
      Bells.disable(author, post)

      mention =
        publish(fake_user!(), "@#{author.character.username} still, about this",
          reply_to_id: post.id
        )

      assert notified?(author, mention)
    end
  end

  # "Unsubscribe from all" means all, your own posts' included; "from what I follow" leaves what you wrote alone
  describe "unsubscribing in bulk" do
    setup %{author: author, reader: reader} do
      mine = publish(reader, "my own post")
      theirs = publish(author, "their post")
      {:ok, _} = Bells.enable(reader, theirs)
      {:ok, _} = Bells.enable(reader, author)

      {:ok, mine: mine, theirs: theirs}
    end

    test "counts all of them, or only what you follow", %{reader: reader} do
      # your own post, their post, and them
      assert Bells.count(reader, :all) == 3
      assert Bells.count(reader, :followed) == 2
    end

    test "from what you follow leaves your own posts' notifications on", %{
      reader: reader,
      author: author,
      mine: mine,
      theirs: theirs
    } do
      Bells.disable_all(reader, :followed)

      assert Bells.enabled?(reader, mine)
      refute Bells.enabled?(reader, theirs)
      refute Bells.enabled?(reader, author)
    end

    test "from all turns them all off", %{reader: reader, mine: mine, theirs: theirs} do
      Bells.disable_all(reader, :all)

      refute Bells.enabled?(reader, mine)
      refute Bells.enabled?(reader, theirs)
      assert Bells.count(reader, :all) == 0
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

    # whichever activity brings it (the post itself, or the group's automatic boost of it), a post in a group with a bell on is news from that group, not somebody boosting the reader's post, so it is not under Boosts: neither its chip nor its switches
    test "a post in a group with a bell on is not under Boosts tab", %{
      group: group,
      reader: reader
    } do
      member(group, reader)
      assert {:ok, _} = Bells.enable(reader, group)
      post = post_in(group, "<p>news for the group</p>")

      # the positive first: it did reach the reader
      assert notified?(reader, post)

      # the reader's notifications through the `:notifications` preset, as the page loads them, narrowed by a category the way a chip is. `feed_name` goes with the filters, or a partial filter map turns the feed into `:custom`
      notifications = fn filters ->
        Bonfire.Social.FeedLoader.feed(
          :notifications,
          Map.merge(%{feed_name: :notifications}, filters),
          current_user: reader
        )
      end

      # the chip, through the same condition the Boosts chip and its switch use. First what does belong there, so the refute below can't pass on a query that finds nothing
      own_post = publish(reader, "a post of the reader's own")
      {:ok, _} = Bonfire.Social.Boosts.boost(fake_user!(), own_post)
      under_boosts = notifications.(%{notification_categories: [:boost]})

      assert Bonfire.Social.FeedLoader.feed_contains?(under_boosts, own_post,
               current_user: reader
             )

      refute Bonfire.Social.FeedLoader.feed_contains?(under_boosts, post, current_user: reader)

      # the switches, as push and email decide it for each activity that arrived
      about_the_post =
        notifications.(%{})
        |> e(:edges, [])
        |> Enum.map(&(e(&1, :activity, nil) || &1))
        |> Enum.filter(&(e(&1, :object_id, nil) == Bonfire.Common.Types.uid(post)))
        |> Bonfire.Common.Repo.maybe_preload([:verb, :tags, replied: [reply_to: :created]])

      assert [_ | _] = about_the_post

      for activity <- about_the_post do
        experience = Bonfire.Social.Activities.experienced_as(activity, reader)

        refute Bonfire.Social.Notifications.category_for(experience) == :boost,
               "#{inspect(experience)} falls under Boosts"
      end
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
