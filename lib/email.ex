defmodule Bonfire.Notify.Email do
  @moduledoc """
  Email as a delivery channel, for someone who asked to be emailed as things happen.

  `Bonfire.Notify.Preferences` lets this channel through only for a category whose Email setting is Instant, which is not the default. Unset leaves it to the digest (`Bonfire.Notify.Digest`), and Off to nothing.

  A target is a person's account address, and only a confirmed one: an address nobody confirmed may not be theirs. Personas sharing an account share its address, and each gets its own email, since each is its own recipient with its own switches.

  Sent inline inside the delivery job (`Bonfire.Mailer.send_now/3`), not with `send_async/3`, which starts a task nobody watches: the job is what retries a failed send, so it has to see the failure.
  """
  @behaviour Bonfire.Notify.Channel

  use Bonfire.Common.E
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]
  import Untangle

  alias Bonfire.Data.Identity.Accounted
  alias Bonfire.Data.Identity.Email, as: Address

  @doc "Whether this instance sends mail: `Swoosh.Adapters.Local` only keeps it in the dev mailbox, which is not sending it to anyone."
  @impl Bonfire.Notify.Channel
  def configured? do
    case Bonfire.Common.Config.get([Bonfire.Mailer.Swoosh, :adapter], nil, :bonfire_mailer) do
      Swoosh.Adapters.Local -> false
      _ -> Bonfire.Common.Extend.module_enabled?(Bonfire.Mailer)
    end
  end

  @doc "Each of these people whose account has a confirmed address, in one query."
  @impl Bonfire.Notify.Channel
  def targets(user_ids, _verb \\ nil) when is_list(user_ids) do
    addresses()
    |> where([accounted: accounted], accounted.id in ^user_ids)
    |> select([accounted: accounted, address: address], %{
      user_id: accounted.id,
      target_id: address.id
    })
    |> repo().all()
  end

  @doc """
  Re-reads the address at delivery time, as this person's, so a changed or unconfirmed one is not written to.

  With the person, since the email shows the activity as they would read it.
  """
  @impl Bonfire.Notify.Channel
  def target(address_id, user_id) when is_binary(address_id) and is_binary(user_id) do
    addresses()
    |> where(
      [accounted: accounted, address: address],
      accounted.id == ^user_id and address.id == ^address_id
    )
    |> select([address: address], address)
    |> repo().one()
    |> case do
      nil -> {:error, :inactive}
      address -> {:ok, %{address: address, user: reader(user_id)}}
    end
  end

  # what the activity's template reads about whoever is reading it
  defp reader(user_id) do
    repo().get(Bonfire.Data.Identity.User, user_id)
    # `:peered` because rendering asks whether the reader is local (their own posts link differently from a remote one's)
    |> repo().maybe_preload([:profile, character: [:peered]])
  end

  defp addresses do
    from(accounted in Accounted,
      as: :accounted,
      join: address in Address,
      as: :address,
      on: address.id == accounted.account_id,
      where: not is_nil(address.confirmed_at)
    )
  end

  @doc """
  Sends one notification's content to one address, and says what the job should do next.

  A mailer that timed out or whose service refused is worth another attempt. A mailer with no configuration is not, since no number of retries configures one.
  """
  @impl Bonfire.Notify.Channel
  def deliver(%{address: %Address{email_address: to}, user: reader}, content, _opts \\ [])
      when is_binary(to) do
    Bonfire.Notify.EmailContent.new(content, reader)
    |> Bonfire.Mailer.send_now(to)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} when reason in [:mailer_config] ->
        {:cancel, reason}

      {:error, {:no_to_recipients, _} = reason} ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      # with where it happened, since what failed is usually a template several components down
      error(Exception.format(:error, exception, __STACKTRACE__), "Could not email a notification")
      {:error, exception}
  end

  def deliver(_target, _content, _opts), do: {:cancel, :no_address}
end
