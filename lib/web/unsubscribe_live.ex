defmodule Bonfire.Notify.Web.UnsubscribeLive do
  @moduledoc """
  Turning notifications off in bulk: from what you follow (people, groups, and posts you didn't write), or from everything, your own posts' included.

  Mounted in the page's reusable modal when it is opened (`OpenModalLive`'s `modal_component`), so the two counts are asked then, and not for every render of the preferences panel that offers it.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  alias Bonfire.Notify.Bells

  data followed_count, :integer, default: nil
  data all_count, :integer, default: nil

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     if(is_nil(e(assigns(socket), :all_count, nil)), do: assign_counts(socket), else: socket)}
  end

  def handle_event("unsubscribe", %{"which" => which}, socket) do
    user = current_user_required!(socket)
    which = if which == "all", do: :all, else: :followed

    {:ok, count} = Bells.disable_all(user, which)

    {:noreply,
     socket
     |> assign_counts()
     |> assign_flash(
       :info,
       lp(
         "Stopped notifications from %{count} thing",
         "Stopped notifications from %{count} things",
         count, count: count)
     )}
  end

  defp assign_counts(socket) do
    user = current_user(socket)

    assign(socket,
      followed_count: if(user, do: Bells.count(user, :followed), else: 0),
      all_count: if(user, do: Bells.count(user, :all), else: 0)
    )
  end
end
