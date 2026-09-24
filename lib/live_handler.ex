defmodule Bonfire.Notify.LiveHandler do
  @moduledoc """
  The events any page can raise for this extension: composing and sending an admin announcement.

  Everything about push subscriptions lives with `Bonfire.Notify.Settings.PushNotificationsLive` instead, because it is what holds the state those events change (which devices someone has, whether *this* browser is subscribed, what permission it reports). This module used to carry a second copy of that surface, `subscribe`, `unsubscribe`, `test_notification`, `remove_subscription` and `refresh_subscriptions`, for a component that was never mounted; a handler here would have had to push that state into every host page's assigns.
  """

  use Bonfire.UI.Common.Web, :live_handler
  import Untangle

  @doc """
  "Send me a test digest", for instance admins: their own digest, now, covering the last 30 days so there is plenty to look at. It does not touch the schedule. Checked here as well as by the button being shown only to admins, since an event can be sent without its button.
  """
  def handle_event("send_test_digest", _params, socket) do
    account = current_account(socket)

    if Bonfire.Me.Accounts.is_admin?(account) do
      case Bonfire.Notify.Digest.send_now(account,
             since: DateTime.add(DateTime.utc_now(), -30, :day)
           ) do
        {:ok, :nothing} ->
          {:noreply,
           assign_flash(socket, :info, l("Nothing from the last 30 days to put in a digest"))}

        {:ok, _email} ->
          {:noreply, assign_flash(socket, :info, l("Test digest sent to your email"))}

        other ->
          error(other, "Could not send a test digest")
          {:noreply, assign_error(socket, l("Could not send the test digest"))}
      end
    else
      {:noreply, assign_error(socket, l("Only instance admins can send a test digest"))}
    end
  end

  def handle_event("broadcast_open", %{"id" => object_id}, socket) do
    _current_user = current_user_required!(socket)

    with {:ok, object} <-
           Bonfire.Common.Needles.get(object_id,
             skip_boundary_check: true,
             preload: [:with_creator, :with_content]
           ) do
      quote_url = Bonfire.Common.URIs.canonical_url(object)

      if quote_url do
        Bonfire.UI.Common.SmartInput.LiveHandler.open_with_text_suggestion(
          "",
          [
            quoted_object: object,
            quoted_url: quote_url,
            smart_input_opts: %{create_object_type: :broadcast}
          ],
          socket
        )

        {:noreply, socket}
      else
        {:noreply, assign_error(socket, l("Could not generate URL for this post"))}
      end
    else
      _ ->
        {:noreply, assign_error(socket, l("Could not broadcast this post"))}
    end
  end

  def handle_event("broadcast", params, socket) do
    admin = current_user_required!(socket)

    with {:ok, published} <- Bonfire.Posts.LiveHandler.publish_post(params, socket),
         {:ok, _published, count} <-
           Bonfire.Notify.Broadcast.broadcast(admin, published, params) do
      {:noreply,
       socket
       |> Bonfire.UI.Common.SmartInput.LiveHandler.reset_input()
       |> assign_flash(
         :info,
         lp("Announcement sent to %{count} user!", "Announcement sent to %{count} users!", count,
           count: count
         )
       )}
    else
      e ->
        error(e, "Could not send announcement")
        {:noreply, assign_flash(socket, :error, l("Could not send the announcement"))}
    end
  end
end
