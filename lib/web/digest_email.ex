defmodule Bonfire.Notify.DigestEmail do
  @moduledoc """
  The digest email's body, rendered by `Bonfire.Notify.Digest` inside the email layout (`Bonfire.UI.Common.Email.Basic`, through `Bonfire.Mailer.Render.templated/4`), as sections for its card: a title and intro, then one section per persona of the account, each under a header naming them, with their notifications as the feed shows them.

  Assigns: `title` and `intro` (also the inbox preheader), `notifications_url` and `settings_url` (the footer's links), and `sections`, each `%{name:, username:, count:, rows:}` where each row is `%{mjml:, text:}`, already rendered by `Bonfire.Notify.EmailContent.activity_email/2`.
  """
  use Bonfire.UI.Common.Web, :function_component
end
