defmodule Bonfire.Notifications.UserNotifications do
  @moduledoc """
  The Notifications context.
  """

  import Ecto.Query

  @repo Application.get_env(:bonfire_notifications, :repo_module)

  # import Bonfire.Notifications.Gettext

  alias Bonfire.Notifications.Events
  alias Bonfire.Notifications.Repo
  alias Bonfire.Notifications.Notification
  alias Bonfire.Data.Identity.User

  @doc """
  A query for notifications.
  """
  @spec query(User.t()) :: Ecto.Query.t()
  def query(%User{id: user_id}) do
    from n in Notification,
      join: u in assoc(n, :users),
      where: u.id == ^user_id
  end

  def query(%User{id: user_id}, %{id: activity_id}) do
    topic = "activity:#{activity_id}"
    from n in Notification, where: n.topic == ^topic and n.user_id == ^user_id
  end

  @doc """
  Fetches notification records for given user and activity.
  """
  def list(%User{} = user, %{} = activity) do
    user
    |> query(activity)
    |> @repo.all()
  end

  @doc """
  Fetches a notification by id.
  """
  @spec get_notification(User.t(), String.t()) :: {:ok, Notification.t()} | {:error, String.t()}
  def get_notification(%User{} = user, id) do
    user
    |> query()
    |> @repo.get(id)
    |> after_get_notification()
  end

  defp after_get_notification(%Notification{} = notification) do
    {:ok, notification}
  end

  defp after_get_notification(_) do
    # {:error, dgettext("errors", "Notification not found")}
  end


  @doc """
  Records an activity notification.
  """

  def record_notification(%User{} = user, data, type \\ "REPLY_CREATED") do

    user
    |> insert_record(type, "activity:#{Map.get(data, :id)}", data)
    |> after_record(user)
  end



  defp insert_record(user, event_type, topic, data) do
    params = %{
      user_id: user.id,
      event_type: event_type,
      topic: topic,
      data: data
    }

    %Notification{}
    |> Ecto.Changeset.change(params)
    |> @repo.insert()
  end

  defp after_record({:ok, notification}, user) do
    Events.notification_created(user.user_id, notification)
    {:ok, notification}
  end

  defp after_record(err, _), do: err

  @doc """
  Dismiss notifications by topic.
  """
  @spec dismiss_topic(User.t(), String.t(), NaiveDateTime.t()) :: {:ok, String.t()}
  def dismiss_topic(%User{} = user, topic, now \\ nil) do
    now = now || NaiveDateTime.utc_now()

    user
    |> query()
    |> with_topic(topic)
    |> where([n], state_dismissed: false)
    |> @repo.update_all(set: [state_dismissed: true, updated_at: now])
    |> after_dismiss_topic(user, topic)
  end

  defp with_topic(query, nil), do: query
  defp with_topic(query, topic), do: where(query, [n], n.topic == ^topic)

  defp after_dismiss_topic(_, user, topic) do
    Events.notifications_dismissed(user.id, topic)
    {:ok, topic}
  end

  @doc """
  Dismiss notification by ID.
  """
  @spec dismiss_notification(User.t(), Notification.t()) ::
          {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_notification(%User{} = user, %Notification{} = notification) do
    notification
    |> Ecto.Changeset.change(state_dismissed: true)
    |> @repo.update()
    |> after_dismiss_notification(user)
  end

  defp after_dismiss_notification({:ok, notification}, user) do
    Events.notification_dismissed(user.id, notification)
    {:ok, notification}
  end

  defp after_dismiss_notification(err, _), do: err
end
