defmodule Bonfire.Notify.Web.MastoStreamingController do
  @moduledoc """
  SSE streaming endpoint.

  Subscribes to the authenticated user's existing PubSub notification
  broadcasts and forwards them as Server-Sent Events over HTTP chunked
  transfer. Used by the Tauri desktop app for real-time OS notifications.

  ## Endpoint

      GET /api/v1-bonfire/streaming?stream=user:notification

  ## Authentication

  Requires a valid Bearer token (same as other Mastodon-compatible API routes).
  """

  use Bonfire.UI.Common.Web, :controller

  @heartbeat_interval_ms 30_000

  @doc """
  Initiates an SSE stream for the authenticated user's notifications.

  Sets appropriate headers for SSE (`text/event-stream`, no caching,
  no proxy buffering) and enters a chunked response loop that forwards
  PubSub messages as SSE events.
  """
  def stream(conn, _params) do
    current_user = conn.assigns[:current_user]

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    subscribe_and_stream(conn, current_user)
  end

  defp subscribe_and_stream(conn, current_user) do
    feed_id =
      Bonfire.Common.Utils.maybe_apply(
        Bonfire.Social.Feeds,
        :my_feed_id,
        [:notifications, current_user]
      )

    if feed_id do
      topic = to_string(feed_id)
      Phoenix.PubSub.subscribe(Bonfire.Common.PubSub, topic)
      stream_loop(conn)
    else
      conn
    end
  end

  defp stream_loop(conn) do
    receive do
      {Bonfire.UI.Common.Notifications, %{} = data} ->
        event =
          Jason.encode!(%{
            title: data[:title],
            body: data[:message],
            url: data[:url],
            icon: data[:icon]
          })

        case Plug.Conn.chunk(conn, "event: notification\ndata: #{event}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, :closed} -> conn
        end

      {:new_message, %{} = data} ->
        event = Jason.encode!(%{type: "message", thread_id: data[:thread_id]})

        case Plug.Conn.chunk(conn, "event: message\ndata: #{event}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, :closed} -> conn
        end
    after
      @heartbeat_interval_ms ->
        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, :closed} -> conn
        end
    end
  end
end
