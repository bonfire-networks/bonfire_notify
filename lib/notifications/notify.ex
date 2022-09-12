defmodule Bonfire.Notify.Notify do
  @moduledoc """
  Responsible for sending notifications

  TODO: refactor based on how we use it
  """

  alias Bonfire.Notify.UserNotifications
  alias Bonfire.Notify.WebPush

  alias Bonfire.Data.Identity.User

  def notify(object, %User{id: user_id} = user) when is_binary(user_id) do
    creator = Map.get(object, :creator, %{})

    record_notifications(object, creator, [user])

    payload = build_push_payload(object, creator, Map.get(object, :context, %{}))

    WebPush.send_web_push(user_id, payload)
  end

  # TODO: dedup
  def notify(object, subscribers) when is_list(subscribers) do
    creator = Map.get(object, :creator, %{})

    record_notifications(object, creator, subscribers)

    payload = build_push_payload(object, creator, Map.get(object, :context, %{}))

    send_push_notifications(object, creator, Map.get(object, :context, %{}))

    :ok
  end

  defp record_notifications(object, creator, subscribers) do
    Enum.each(subscribers, fn subscriber ->
      if Map.get(subscriber, :id) !== Map.get(creator, :id) do
        UserNotifications.record_notification(subscriber, object, "MESSAGE")
      end
    end)
  end

  defp send_push_notifications(context, payload, creator) do
    UserSubscriptions.list()
    |> Enum.filter(fn {_, value} ->
      Enum.any?(value.metas, fn meta -> meta.expanded end)
    end)
    |> Enum.map(fn {key, _} -> key end)
    |> Enum.each(fn user_id ->
      if user_id != Map.get(creator, :id) do
        WebPush.send_web_push(user_id, payload)
      end
    end)
  end

  @doc """
  Builds a payload for a push notifications.
  """
  def build_push_payload(%{} = object, creator, context) do
    # |> StringHelpers.truncate()
    body =
      Map.get(creator, :name) <> ": " <> Map.get(object, :summary) ||
        Map.get(object, :content)

    payload = %WebPush.Payload{
      title: Map.get(object, :name),
      body: body,
      require_interaction: true,
      url: Map.get(object, :url) || Map.get(object, :canonical_url),
      tag: nil
    }
  end
end
