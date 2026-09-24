defmodule Bonfire.Notify.BellWordingTest do
  @moduledoc """
  How a reply reads in your notifications: "replied to you" only when it answered a post of yours. A reply that reached you through a bell on its thread answered someone else, and says so.
  """
  use Bonfire.Notify.ConnCase, async: true
  @moduletag :ui

  setup do
    account = fake_account!()
    reader = fake_user!(account)

    {:ok, conn: conn(user: reader, account: account), reader: reader}
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

  test "a reply to your post reads as replied to you", %{conn: conn, reader: reader} do
    root = publish(reader, "the reader's own post")
    publish(fake_user!("Direct Replier"), "an answer to the reader", reply_to_id: root.id)

    conn
    |> visit("/notifications")
    |> wait_async()
    |> assert_has("[data-id=feed] article", text: "Direct Replier replied to you")
  end

  test "a reply in a thread you have a bell on reads as such, not as replied to you", %{
    conn: conn,
    reader: reader
  } do
    root = publish(fake_user!(), "someone else's thread")
    {:ok, _} = Bonfire.Notify.Bells.enable(reader, root)
    publish(fake_user!("Thread Replier"), "a reply in the thread", reply_to_id: root.id)

    conn
    |> visit("/notifications")
    |> wait_async()
    |> assert_has("[data-id=feed] article", text: "Thread Replier replied to a discussion")
    |> refute_has("[data-id=feed] article", text: "Thread Replier replied to you")
  end
end
