defmodule Bonfire.Notify.EmailContent do
  @moduledoc """
  A notification's content (`Bonfire.Notify.Content`) as an email: the activity as the feed shows it, through `Bonfire.UI.Social.ActivityLive`'s email template, inside the email layout (`Bonfire.Mailer.Render.templated/4`).

  Rendered for the person it is sent to, since what an activity says turns on who reads it (a post is a mention to the person it names), and in the language the notification was assembled in, which the content records as `locale`. Both UI modules are asked rather than named, so this extension does not depend on them; without them the email says what a push says.
  """
  use Bonfire.Common.E
  import Untangle

  @doc "An email, without a recipient, for this notification content and the person reading it."
  def new(content, reader) do
    # `ed` rather than `e`: a delivery job's arguments are JSON, so their keys come back as strings
    title = ed(content, :title, nil) || Bonfire.Mailer.app_name()
    # an email is read away from the instance, so a path alone leads nowhere
    url = ed(content, :url, nil) |> Bonfire.UI.Common.SEOImage.absolute_url()
    activity_id = ed(content, :activity_id, nil)

    Bonfire.Notify.Deliveries.in_locale(ed(content, :locale, nil), fn ->
      email = Bonfire.Mailer.new() |> Bonfire.Mailer.subject(title)

      with activity when not is_nil(activity) <- activity(activity_id, reader),
           %Swoosh.Email{html_body: html} = rendered when is_binary(html) and html != "" <-
             Bonfire.Common.Utils.maybe_apply(
               Bonfire.Mailer.Render,
               :templated,
               [email, Bonfire.UI.Social.ActivityLive, assigns(activity, url, reader)],
               fallback_return: nil
             ) do
        # the text part is the activity's text template; a push's words stand in only when it came out empty
        if blank?(rendered.text_body),
          do: Bonfire.Mailer.text_body(rendered, plain(content, url)),
          else: rendered
      else
        other ->
          debug(other, "no activity preview, so the email says what a push says")
          Bonfire.Mailer.text_body(email, plain(content, url))
      end
    end)
  end

  @doc """
  One activity as `%{mjml:, text:}` for this reader, both from one preparation, through `ActivityLive`'s email templates. Without a layout, and the MJML not yet HTML, so several can go in one email (the digest). The same rendering an instant email uses. `nil` when the UI extension that owns the templates is not there.
  """
  def activity_email(activity, reader) do
    assigns = activity |> preloaded(reader) |> assigns(nil, reader)

    with mjml when is_binary(mjml) <- render_part(assigns, "mjml") do
      %{mjml: mjml, text: render_part(assigns, "text") || ""}
    end
  end

  defp render_part(assigns, format) do
    case Bonfire.Common.Utils.maybe_apply(
           Bonfire.Mailer.Render,
           :render_to_string,
           [Bonfire.UI.Social.ActivityLive, "activity_live", format, assigns],
           fallback_return: nil
         ) do
      nil -> nil
      "" -> nil
      # a text template gives plain text, which `Phoenix.HTML.Safe` would escape as if it were going into HTML
      text when is_binary(text) or is_list(text) -> IO.iodata_to_binary(text)
      rendered -> rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    end
  end

  # loaded as a feed row is, for the person reading, since that is what the template renders from
  defp activity(nil, _reader), do: nil

  defp activity(activity_id, reader) do
    with {:ok, activity} <-
           Bonfire.Common.Utils.maybe_apply(
             Bonfire.Social.Activities,
             :get,
             [activity_id, [current_user: reader, skip_boundary_check: true]],
             fallback_return: nil
           ) do
      preloaded(activity, reader)
    else
      _ -> nil
    end
  end

  # what is already loaded (a feed row the digest has in hand) is left as it is
  defp preloaded(activity, reader) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Activities,
      :activity_preloads,
      [activity, feed_preloads(), [current_user: reader, skip_boundary_check: true]],
      fallback_return: activity
    )
  end

  # what a feed row renders from: `:feed` is what loads the object's own content (a post's text), which the other two leave out. `:with_request_edge` is what says what an ask was for (to follow, to join, to quote), which the notifications feed loads only for its Latest and Requests views, not for the categories a digest asks for. `:sensitivity` is whether the post is behind a content warning, which an instant email, loaded by id, would otherwise not know
  defp feed_preloads do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.FeedLoader,
      :map_activity_preloads,
      [[:feed, :feed_metadata, :feed_postload, :with_request_edge, :sensitivity]],
      fallback_return: []
    )
  end

  defp assigns(activity, url, reader) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.UI.Social.ActivityLive,
      :prepare_assigns,
      [
        %{
          activity: activity,
          object: nil,
          # an email of a notification is the row the notifications feed shows for it, with the wording and parts written for that feed ("replied to you")
          showing_within: :notifications,
          permalink: url,
          current_user: reader,
          __context__: %{current_user: reader}
        }
      ],
      fallback_return: %{}
    )
  end

  defp plain(content, url),
    do: [ed(content, :body, nil), url] |> Enum.reject(&blank?/1) |> Enum.join("\n\n")

  defp blank?(text), do: is_nil(text) or text == ""
end
