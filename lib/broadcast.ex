defmodule Bonfire.Notify.Broadcast do
  @moduledoc "Context for admin broadcast announcements."

  use Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]

  @doc """
  Publishes a post and pushes it to the appropriate audience's notification feeds,
  including web/native push where enabled.

  - `boundary: "public"` or `boundary: "local"` → all local users
  - custom `to_circles` → members of those circles

  Returns `{:ok, published, recipient_count}`.
  """
  def announce(admin, attrs) do
    if Bonfire.Me.Accounts.is_admin?(admin) ||
         Bonfire.Boundaries.can?(admin, [:moderate, :administer], :instance) do
      do_announce(admin, attrs)
    else
      {:error, :unauthorized}
    end
  end

  defp do_announce(admin, attrs) do
    boundary = e(attrs, :to_boundaries, "local")
    to_circles = e(attrs, :to_circles, [])

    with {:ok, published} <-
           Bonfire.Posts.publish(
             post_attrs: attrs,
             context: admin,
             boundary: boundary,
             to_circles: to_circles
           ) do
      activity = e(published, :activity, nil)
      recipients = resolve_recipients(boundary, to_circles)

      notification_feed_ids =
        Bonfire.Social.FeedActivities.get_publish_feed_ids(notifications: recipients)

      Bonfire.Social.FeedActivities.maybe_feed_publish(
        admin,
        activity,
        published,
        notification_feed_ids,
        []
      )

      Bonfire.Social.LivePush.notify(admin, :announce, published,
        feed_ids: notification_feed_ids,
        notify: true
      )

      {:ok, published, length(recipients)}
    end
  end

  defp resolve_recipients(boundary, to_circles)
       when boundary in ["public", "local", :public, :local] or to_circles == [] do
    Bonfire.Me.Users.Queries.list(:local) |> repo().all()
  end

  defp resolve_recipients(_boundary, to_circles) do
    circle_ids =
      Enum.map(to_circles, fn
        {_name, id} -> id
        id when is_binary(id) -> id
      end)

    Bonfire.Boundaries.Circles.list_members_in_all_circles(circle_ids)
    |> e(:edges, [])
    |> Enum.map(&e(&1, :subject, nil))
    |> Enum.reject(&is_nil/1)
  end
end
