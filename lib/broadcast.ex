defmodule Bonfire.Notify.Broadcast do
  @moduledoc "Context for admin broadcast announcements."

  use Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]

  @doc """
  Publishes a post and pushes it to the appropriate audience's notification feeds,
  including web/native push where enabled. Delegates to `broadcast/3` after publishing.

  - `boundary: "public"` or `boundary: "local"` → all local users
  - custom `to_circles` → members of those circles

  Returns `{:ok, published, recipient_count}`.
  """
  def broadcast(admin, attrs) do
    boundary = e(attrs, :to_boundaries, "local")
    to_circles = e(attrs, :to_circles, [])

    # check_permission(admin) is intentionally skipped here — broadcast/3 checks it
    with {:ok, published} <-
           Bonfire.Posts.publish(
             post_attrs: attrs,
             context: admin,
             boundary: boundary,
             to_circles: to_circles
           ) do
      broadcast(admin, published, attrs)
    end
  end

  @doc """
  Pushes an already-published post to the appropriate audience's notification feeds.
  Called from the live handler after `Bonfire.Posts.LiveHandler.publish_post/3`.
  """
  def broadcast(admin, published, params) do
    boundary = e(params, "to_boundaries", e(params, :to_boundaries, "local"))
    to_circles = e(params, "to_circles", e(params, :to_circles, []))

    with :ok <- check_permission(admin) do
      notify_recipients(admin, published, boundary, to_circles)
    end
  end

  defp check_permission(admin) do
    if Bonfire.Me.Accounts.is_admin?(admin) ||
         Bonfire.Boundaries.can?(admin, :moderate, :instance) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp notify_recipients(admin, published, boundary, to_circles) do
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

    Bonfire.Social.LivePush.notify(admin, :broadcast, published,
      feed_ids: notification_feed_ids,
      notify: true
    )

    {:ok, published, length(recipients)}
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
