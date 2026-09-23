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
    url = ed(content, :url, nil) |> absolute_url()

    email = Bonfire.Mailer.new() |> Bonfire.Mailer.subject(title)

    in_locale(ed(content, :locale, nil), fn ->
      with activity when not is_nil(activity) <- activity(ed(content, :activity_id, nil), reader),
           %Swoosh.Email{html_body: html} = rendered when is_binary(html) and html != "" <-
             Bonfire.Common.Utils.maybe_apply(
               Bonfire.Mailer.Render,
               :templated,
               [email, Bonfire.UI.Social.ActivityLive, assigns(activity, url, reader)],
               fallback_return: nil
             ) do
        # the activity components have no text templates yet, so the text part says what a push says
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

  # loaded as a feed row is, for the person reading, since that is what the template renders from
  defp activity(nil, _reader), do: nil

  defp activity(activity_id, reader) do
    opts = [current_user: reader, skip_boundary_check: true]

    with {:ok, activity} <-
           Bonfire.Common.Utils.maybe_apply(Bonfire.Social.Activities, :get, [activity_id, opts],
             fallback_return: nil
           ) do
      Bonfire.Common.Utils.maybe_apply(
        Bonfire.Social.Activities,
        :activity_preloads,
        [activity, feed_preloads(), opts],
        fallback_return: activity
      )
    else
      _ -> nil
    end
  end

  # what a feed row renders from: `:feed` is what loads the object's own content (a post's text), which the other two leave out
  defp feed_preloads do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.FeedLoader,
      :map_activity_preloads,
      [[:feed, :feed_metadata, :feed_postload]],
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
          permalink: url,
          current_user: reader,
          __context__: %{current_user: reader}
        }
      ],
      fallback_return: %{}
    )
  end

  defp in_locale(nil, fun), do: fun.()

  defp in_locale(locale, fun) do
    previous = Bonfire.Common.Localise.get_locale()
    Bonfire.Common.Localise.put_locale(locale)

    try do
      fun.()
    after
      Bonfire.Common.Localise.put_locale(previous)
    end
  end

  defp plain(content, url),
    do: [ed(content, :body, nil), url] |> Enum.reject(&blank?/1) |> Enum.join("\n\n")

  defp blank?(text), do: is_nil(text) or text == ""

  # an email is read away from the instance, so a path alone leads nowhere
  defp absolute_url(nil), do: nil
  defp absolute_url("/" <> _ = path), do: Bonfire.Common.URIs.base_url() <> path
  defp absolute_url(url), do: url
end
