defmodule Bonfire.Notify.Web.BellButtonLive do
  @moduledoc """
  A bell: "Notify me about new posts" on a person or group (or replies, on a thread). Off until pressed.

  Where it is shown is the caller's choice, not this component's: the follow button renders it once someone follows, but nothing here requires following. A caller that already knows whether the bell is on passes `enabled`, and otherwise it is asked once.

  Rendered by the UI extensions through `maybe_component`, so they do not depend on this one.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  alias Bonfire.Notify.Bells

  @doc "The person, group or thread the bell is on."
  prop object, :any, default: nil

  @doc "Whether the bell is already on, when the caller knows. Asked when left `nil`."
  prop enabled, :any, default: nil

  @doc "What pressing it turns on, and off, which depends on what it is on: new posts for a person or group, replies for a thread."
  prop label, :string, default: nil
  prop label_enabled, :string, default: nil

  @doc "A caveat the tooltip adds after the label, for example that only replies reaching this server are covered."
  prop hint, :string, default: nil

  @doc "Ask whether it's on only when told to (a `load` event, pushed by the menu it sits in when that opens), rather than when rendered, so a page of posts asks nothing up front."
  prop lazy, :boolean, default: false

  @doc "Render as a row in a menu rather than as a round button."
  prop menu_item, :boolean, default: false

  @doc "Optional button classes for callers that need the bell to match a surrounding action group."
  prop button_class, :css_class, default: nil

  @doc "Optional button classes for the enabled state, falling back to `button_class`."
  prop button_class_enabled, :css_class, default: nil

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     if(is_nil(e(assigns(socket), :enabled, nil)) and !e(assigns(socket), :lazy, false),
       do: assign_enabled(socket),
       else: socket
     )}
  end

  # the menu it sits in was opened: ask now, once
  def handle_event("load", _params, socket) do
    {:noreply,
     if(is_nil(e(assigns(socket), :enabled, nil)), do: assign_enabled(socket), else: socket)}
  end

  def handle_event("toggle", _params, socket) do
    user = current_user_required!(socket)
    object = e(assigns(socket), :object, nil)

    if e(assigns(socket), :enabled, false) == true do
      Bells.disable(user, object)
      {:noreply, assign(socket, enabled: false)}
    else
      case Bells.enable(user, object) do
        {:ok, _} ->
          {:noreply, assign(socket, enabled: true)}

        other ->
          error(other, "Could not enable the bell")
          {:noreply, assign_error(socket, l("Could not turn on notifications for their posts"))}
      end
    end
  end

  defp assign_enabled(socket) do
    user = current_user(socket)
    object = e(assigns(socket), :object, nil)
    assign(socket, enabled: not is_nil(user) and Bells.enabled?(user, object))
  end
end
