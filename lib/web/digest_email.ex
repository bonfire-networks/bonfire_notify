defmodule Bonfire.Notify.DigestEmail do
  @moduledoc """
  The digest email's body, rendered by `Bonfire.Notify.Digest` inside the email layout (`Bonfire.Mailer.Render.templated/4`): an intro, then one section per persona of the account, each under a header naming them, with their notifications as the feed shows them.

  Assigns: `intro`, and `sections`, each `%{name:, username:, count:, activities:}` where `activities` are MJML already rendered by `Bonfire.Notify.EmailContent.activity_mjml/2`.
  """
  use Bonfire.UI.Common.Web, :function_component
end
