defmodule Bonfire.Notify.MastoStreaming.EventFormatter do
  @moduledoc """
  Formats PubSub activity data into Mastodon WebSocket streaming JSON frames.

  For streaming, uses a lightweight formatter that extracts data from the
  already-preloaded PubSub activity without making DB queries. This avoids
  blocking the WebSocket process on Ecto pool checkouts.

  ## Wire format (per Mastodon WebSocket spec)

      {"stream":["user"],"event":"update","payload":"{\"id\":...}"}

  The `payload` field is double-encoded JSON (a JSON string containing JSON).
  """

  import Untangle
  use Bonfire.Common.Utils

  @doc """
  Format an activity as a Mastodon `update` event (status JSON).

  Uses lightweight extraction from already-preloaded PubSub data.
  No DB queries are made — only reads from the in-memory activity struct.

  Returns `{:ok, json_string}` or `:skip` if the activity can't be mapped.
  """
  def format_update(activity, opts \\ []) do
    activity_id = id(activity) || e(activity, :object_id, nil)
    object = e(activity, :object, nil) || activity

    subject = e(activity, :subject, nil)
    post_content = e(object, :post_content, nil) || e(activity, :object_post_content, nil)

    content =
      e(post_content, :html_body, nil) ||
        e(post_content, :summary, nil) ||
        e(post_content, :name, nil) ||
        ""

    created_at =
      e(activity, :created_at, nil) ||
        e(activity, :date, nil) ||
        DateTime.utc_now()

    account = build_account(subject)

    visibility = detect_visibility(activity)

    uri =
      e(activity, :uri, nil) ||
        Bonfire.Common.URIs.canonical_url(object) ||
        Bonfire.Common.URIs.canonical_url(activity)

    url = uri || "#{Bonfire.Common.URIs.base_url()}/post/#{activity_id}"

    status = %{
      "id" => to_string(activity_id),
      "created_at" => format_datetime(created_at),
      "in_reply_to_id" => e(activity, :replied, :reply_to_id, nil) |> nil_or_string(),
      "in_reply_to_account_id" => nil,
      "sensitive" => e(activity, :sensitive, nil) != nil,
      "spoiler_text" => e(post_content, :name, "") || "",
      "visibility" => visibility,
      "language" => nil,
      "uri" => to_string(uri || url),
      "url" => to_string(url),
      "replies_count" => 0,
      "reblogs_count" => 0,
      "favourites_count" => 0,
      "favourited" => false,
      "reblogged" => false,
      "muted" => false,
      "bookmarked" => false,
      "pinned" => false,
      "content" => content,
      "text" => Bonfire.Common.Text.text_only(content),
      "reblog" => nil,
      "application" => nil,
      "account" => account,
      "media_attachments" => build_media_attachments(object),
      "mentions" => [],
      "tags" => [],
      "emojis" => [],
      "card" => nil,
      "poll" => nil,
      "filtered" => []
    }

    if activity_id do
      {:ok, Jason.encode!(status)}
    else
      :skip
    end
  rescue
    e ->
      error(e, "EventFormatter.format_update failed")
      :skip
  end

  @doc """
  Format an activity as a Mastodon `notification` event.

  Returns `{:ok, json_string}` or `:skip` if the activity can't be mapped.
  """
  def format_notification(activity, opts \\ []) do
    notification_type = detect_notification_type(activity)

    if notification_type do
      subject = e(activity, :subject, nil)
      account = build_account(subject)

      notification = %{
        "id" => to_string(id(activity)),
        "type" => notification_type,
        "created_at" => format_datetime(e(activity, :created_at, nil) || DateTime.utc_now()),
        "account" => account
      }

      # Add status for notification types that include one
      notification =
        if notification_type in ~w(mention status reblog favourite poll update) do
          case format_update(activity, opts) do
            {:ok, status_json} ->
              Map.put(notification, "status", Jason.decode!(status_json))

            :skip ->
              notification
          end
        else
          notification
        end

      {:ok, Jason.encode!(notification)}
    else
      :skip
    end
  rescue
    e ->
      error(e, "EventFormatter.format_notification failed")
      :skip
  end

  @doc """
  Format a conversation event using the Mastodon Conversation entity shape.

  Returns `{:ok, json_string}`.
  """
  def format_conversation(thread_id, _opts \\ []) do
    conversation = %{
      "id" => to_string(thread_id),
      "accounts" => [],
      "unread" => true,
      "last_status" => nil
    }

    {:ok, Jason.encode!(conversation)}
  end

  @doc """
  Format a delete event. Returns `{:ok, id_string}`.
  """
  def format_delete(activity_id) do
    {:ok, to_string(activity_id)}
  end

  @doc """
  Build a complete Mastodon WebSocket JSON frame.
  """
  def to_ws_frame(stream_names, event_type, payload) do
    Jason.encode!(%{
      "stream" => List.wrap(stream_names),
      "event" => event_type,
      "payload" => payload
    })
  end

  # --- Private helpers (no DB queries) ---

  defp build_account(subject) do
    character = e(subject, :character, nil)
    profile = e(subject, :profile, nil)
    subject_id = id(subject)
    username = e(character, :username, nil) || "unknown"

    base_url = Bonfire.Common.URIs.base_url()

    avatar =
      e(profile, :icon, :path, nil) ||
        (subject && Bonfire.Files.Media.avatar_url(subject))

    avatar_url =
      cond do
        is_binary(avatar) and String.starts_with?(avatar, "http") -> avatar
        is_binary(avatar) -> "#{base_url}#{avatar}"
        true -> "#{base_url}/images/avatar_default.png"
      end

    %{
      "id" => to_string(subject_id || "0"),
      "username" => username,
      "acct" => username,
      "display_name" => e(profile, :name, nil) || username,
      "locked" => false,
      "bot" => false,
      "discoverable" => true,
      "group" => false,
      "created_at" => format_datetime(DateTime.utc_now()),
      "note" => e(profile, :summary, "") || "",
      "url" => "#{base_url}/@#{username}",
      "uri" => "#{base_url}/@#{username}",
      "avatar" => avatar_url,
      "avatar_static" => avatar_url,
      "header" => "#{base_url}/images/header_default.png",
      "header_static" => "#{base_url}/images/header_default.png",
      "followers_count" => 0,
      "following_count" => 0,
      "statuses_count" => 0,
      "last_status_at" => nil,
      "emojis" => [],
      "fields" => []
    }
  rescue
    _ -> unknown_account()
  end

  defp unknown_account do
    base_url = Bonfire.Common.URIs.base_url()

    %{
      "id" => "0",
      "username" => "unknown",
      "acct" => "unknown",
      "display_name" => "unknown",
      "locked" => false,
      "bot" => false,
      "discoverable" => false,
      "group" => false,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "note" => "",
      "url" => "#{base_url}/@unknown",
      "uri" => "#{base_url}/@unknown",
      "avatar" => "#{base_url}/images/avatar_default.png",
      "avatar_static" => "#{base_url}/images/avatar_default.png",
      "header" => "#{base_url}/images/header_default.png",
      "header_static" => "#{base_url}/images/header_default.png",
      "followers_count" => 0,
      "following_count" => 0,
      "statuses_count" => 0,
      "last_status_at" => nil,
      "emojis" => [],
      "fields" => []
    }
  end

  defp build_media_attachments(object) do
    files = e(object, :files, nil)

    if is_list(files) do
      Enum.map(files, fn file ->
        media = e(file, :media, nil) || file

        %{
          "id" => to_string(id(media)),
          "type" => detect_media_type(e(media, :media_type, "application/octet-stream")),
          "url" => Bonfire.Files.Media.media_url(media),
          "preview_url" => Bonfire.Files.Media.media_url(media),
          "description" => nil,
          "meta" => nil
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp detect_media_type(mime) when is_binary(mime) do
    cond do
      String.starts_with?(mime, "image") -> "image"
      String.starts_with?(mime, "video") -> "video"
      String.starts_with?(mime, "audio") -> "audio"
      true -> "unknown"
    end
  end

  defp detect_media_type(_), do: "unknown"

  defp detect_visibility(activity) do
    # Check controlled ACLs for visibility hints
    controlled = e(activity, :controlled, nil) || e(activity, :object, :controlled, nil)

    if is_list(controlled) do
      acl_ids = Enum.map(controlled, &e(&1, :acl_id, nil))

      cond do
        "1EVERY0NEMAYSEEEEANDREADDD" in acl_ids -> "public"
        "710CA1SMY1NTERACTANDREP1YY" in acl_ids -> "public"
        "3SERSFR0MY0VR10CA11NSTANCE" in acl_ids -> "unlisted"
        true -> "private"
      end
    else
      "public"
    end
  rescue
    _ -> "public"
  end

  defp detect_notification_type(activity) do
    verb = e(activity, :verb, :verb, nil) || e(activity, :verb_id, nil)

    case verb do
      v when v in ["Like", "40STEN0TE1PPREA11YENJ0YED"] -> "favourite"
      v when v in ["Boost", "70OSTAM0MENTS0METH1NGSA1D"] -> "reblog"
      v when v in ["Follow", "20SVBSCR1BET0S0ME0NESF33D"] -> "follow"
      v when v in ["Create", "4REATE0RP0STBRANDNEW0BJECT"] -> "mention"
      _ -> nil
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp format_datetime(str) when is_binary(str), do: str
  defp format_datetime(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp nil_or_string(nil), do: nil
  defp nil_or_string(val), do: to_string(val)
end
