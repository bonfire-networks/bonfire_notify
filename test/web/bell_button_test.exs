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
        visibility: "global:discoverable"
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
end
