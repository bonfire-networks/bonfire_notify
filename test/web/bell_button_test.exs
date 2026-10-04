defmodule Bonfire.Notify.BellButtonTest do
  @moduledoc """
  The bell on a profile: "Notify me about new posts", beside the follow button, shown only to someone who follows, and off until they press it.
  """
  use Bonfire.Notify.ConnCase, async: true
  @moduletag :ui

  alias Bonfire.Notify.Bells

  setup do
    account = fake_account!()
    reader = fake_user!(account)
    author = fake_user!("Bell Author")

    {:ok, conn: conn(user: reader, account: account), reader: reader, author: author}
  end

  test "on a profile you follow, the bell is off until you press it", %{
    conn: conn,
    reader: reader,
    author: author
  } do
    {:ok, _} = Bonfire.Social.Graph.Follows.follow(reader, author)

    session =
      conn
      |> visit("/@#{author.character.username}")
      |> wait_async()
      |> assert_has("[data-role=bell_button]", text: "Notify me about new posts")

    refute Bells.enabled?(reader, author)

    session
    |> click_button("[data-role=bell_button] button", "Notify me about new posts")
    |> assert_has("[data-role=bell_button]", text: "Stop notifying me")

    assert Bells.enabled?(reader, author)
  end

  test "pressing it again turns it off", %{conn: conn, reader: reader, author: author} do
    {:ok, _} = Bonfire.Social.Graph.Follows.follow(reader, author)
    {:ok, _} = Bells.enable(reader, author)

    conn
    |> visit("/@#{author.character.username}")
    |> wait_async()
    |> click_button("[data-role=bell_button] button", "Stop notifying me")
    |> assert_has("[data-role=bell_button]", text: "Notify me about new posts")

    refute Bells.enabled?(reader, author)
  end

  test "a local person's profile has the bell without following them, since their posts are here either way",
       %{conn: conn, reader: reader, author: author} do
    conn
    |> visit("/@#{author.character.username}")
    |> wait_async()
    |> click_button("[data-role=bell_button] button", "Notify me about new posts")
    |> assert_has("[data-role=bell_button]", text: "Stop notifying me")

    assert Bells.enabled?(reader, author)
  end

  # asked only when that post's menu is opened, so a page of posts asks nothing up front
  test "a reply's menu has a bell for the replies below it, which asks only once the menu is opened, while the thread's root leaves it to the page header",
       %{conn: conn, reader: reader, author: author} do
    {:ok, root} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "a post with a menu"}},
        boundary: "public"
      )

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "a reply with a menu"}, reply_to_id: root.id},
        boundary: "public"
      )

    {:ok, view, _html} = live(conn, "/post/#{root.id}")
    render_async(view)

    reply_menu = "[data-object_id='#{reply.id}']"

    # the positive first: the reply's item is there, waiting to be asked
    assert has_element?(view, "#{reply_menu} [data-role=bell_menu_item]")
    refute has_element?(view, "#{reply_menu} [data-role=bell_menu_item] button")
    # the root has the header's bell instead
    assert has_element?(view, "[data-object_id='#{root.id}'] [data-id=more_menu]")
    refute has_element?(view, "[data-object_id='#{root.id}'] [data-role=bell_menu_item]")
    assert has_element?(view, "[data-role=bell_button]", "Notify me about replies")

    view |> element("#{reply_menu} [data-id=more_menu] [id$=_trigger]") |> render_click()

    assert has_element?(
             view,
             "#{reply_menu} [data-role=bell_menu_item] button",
             "Notify me about replies"
           )

    view |> element("#{reply_menu} [data-role=bell_menu_item] button") |> render_click()

    assert has_element?(
             view,
             "#{reply_menu} [data-role=bell_menu_item] button",
             "Stop notifying me about replies"
           )

    assert Bells.enabled?(reader, reply)
  end

  test "a thread has a bell for its replies, off until you press it", %{
    conn: conn,
    reader: reader,
    author: author
  } do
    {:ok, root} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "a thread worth following"}},
        boundary: "public"
      )

    conn
    |> visit("/post/#{root.id}")
    |> wait_async()
    |> click_button("[data-role=bell_button] button", "Notify me about replies")
    |> assert_has("[data-role=bell_button]", text: "Stop notifying me about replies")

    assert Bells.enabled?(reader, root)
  end

  test "a local group has a bell for its new posts, without joining it", %{
    conn: conn,
    reader: reader,
    author: author
  } do
    group =
      Bonfire.Classify.Simulate.fake_group!(author, %{
        membership: "open",
        visibility: "global"
      })

    conn
    |> visit("/group/#{group.id}")
    |> wait_async()
    |> click_button("[data-role=bell_button] button", "Notify me about new posts")
    |> assert_has("[data-role=bell_button]", text: "Stop notifying me")

    assert Bells.enabled?(reader, group)
  end

  # TODO: a remote group has no bell until you join it, as a remote person's until you follow them (needs remote fixtures)

  # TODO: a remote person's profile has no bell until you follow them, since their posts only reach us through a follow (needs a remote user fixture)

  # one button in the notification preferences panel, opening a modal that only counts once opened, with a choice for each: what you follow, or everything
  describe "unsubscribing in bulk from the preferences panel" do
    setup %{reader: reader, author: author} do
      {:ok, mine} =
        Bonfire.Posts.publish(
          current_user: reader,
          post_attrs: %{post_content: %{html_body: "my own post"}},
          boundary: "public"
        )

      {:ok, theirs} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "their post"}},
          boundary: "public"
        )

      {:ok, _} = Bells.enable(reader, theirs)
      {:ok, _} = Bells.enable(reader, author)

      {:ok, mine: mine}
    end

    test "from what you follow: counts when opened, and leaves your own posts' on", %{
      conn: conn,
      reader: reader,
      mine: mine
    } do
      {:ok, view, _html} = live(conn, "/notifications")
      render_async(view)

      refute has_element?(view, "[data-role=unsubscribe_confirm]")

      view |> element("#notification-unsubscribe [data-role=open_modal]") |> render_click()

      # their post and them
      assert has_element?(view, "[data-role=unsubscribe_followed]", "2")

      view |> element("[data-role=unsubscribe_followed]") |> render_click()

      assert Bells.count(reader, :followed) == 0
      assert Bells.enabled?(reader, mine)
    end

    test "from all: turns off your own posts' too", %{conn: conn, reader: reader, mine: mine} do
      {:ok, view, _html} = live(conn, "/notifications")
      render_async(view)

      view |> element("#notification-unsubscribe [data-role=open_modal]") |> render_click()

      # my post, their post, and them
      assert has_element?(view, "[data-role=unsubscribe_all]", "3")

      view |> element("[data-role=unsubscribe_all]") |> render_click()

      assert Bells.count(reader, :all) == 0
      refute Bells.enabled?(reader, mine)
    end
  end
end
