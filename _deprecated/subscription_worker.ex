defmodule Bonfire.Notify.WebPush.SubscriptionWorker do
  @moduledoc """
  A worker process for sending notifications to a subscription.
  """

  use GenServer
  import Untangle
  import Ecto.Query

  use Bonfire.Common.Config
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Notify.WebPush.Payload
  alias Bonfire.Notify.UserSubscription
  alias Bonfire.Notify.WebPush.Subscription

  defstruct [:digest, :subscription]

  @type t :: %__MODULE__{
          digest: String.t(),
          subscription: Subscription.t()
        }

  # Client

  def start_link([digest, subscription]) do
    if Bonfire.Notify.enabled() do
      GenServer.start_link(__MODULE__, [digest, subscription], name: via_tuple(digest))
    else
      {:error, :not_enabled}
    end
  end

  def registry_key(digest) do
    {:web_push_subscription, digest}
  end

  defp via_tuple(digest) do
    {:via, Registry, {Bonfire.Notify.Registry, registry_key(digest)}}
  end

  def send_web_push(digest, %Payload{} = payload) do
    GenServer.cast(via_tuple(digest), {:send_web_push, payload})
  end

  # Server

  @impl true
  def init([digest, subscription]) do
    {:ok, %__MODULE__{digest: digest, subscription: subscription}}
  end

  @impl true
  def handle_cast({:send_web_push, payload}, state) do
    make_request(state, payload, 0)
  end

  @impl true
  def handle_info({:retry_web_push, payload, attempts}, state) do
    make_request(state, payload, attempts)
  end

  defp make_request(state, payload, attempts) do
    IO.inspect(state: state)
    IO.inspect(payload: payload)

    payload
    |> adapter().make_request(state.subscription)
    |> handle_push_response(state, payload, attempts)
  end

  defp handle_push_response({:ok, %_{status_code: 201}}, state, _, _) do
    {:noreply, state}
  end

  defp handle_push_response({:ok, %_{status_code: 404}}, state, _, _) do
    delete_subscription(state.digest)
    {:stop, :normal, state}
  end

  defp handle_push_response({:ok, %_{status_code: 410}}, state, _, _) do
    delete_subscription(state.digest)
    {:stop, :normal, state}
  end

  defp handle_push_response({:ok, %_{status_code: 400} = resp}, state, _, _) do
    error("Push notification request was invalid: #{inspect(resp)}")
    {:noreply, state}
  end

  defp handle_push_response({:ok, %_{status_code: 429} = resp}, state, _, _) do
    error("Push notifications were rate limited: #{inspect(resp)}")
    {:noreply, state}
  end

  defp handle_push_response({:ok, %_{status_code: 413} = resp}, state, _, _) do
    error("Push notification was too large: #{inspect(resp)}")
    {:noreply, state}
  end

  defp handle_push_response(_, state, payload, attempts) do
    if attempts < max_attempts() - 1 do
      schedule_retry(payload, attempts + 1)
    end

    {:noreply, state}
  end

  defp schedule_retry(payload, attempts) do
    timeout = retry_timeout()
    message = {:retry_web_push, payload, attempts}

    if timeout > 0 do
      Process.send_after(self(), message, timeout)
    else
      send(self(), message)
    end
  end

  defp delete_subscription(digest) do
    digest
    |> by_digest()
    |> repo().delete_all()
    |> handle_delete()
  end

  defp by_digest(digest) do
    from(r in Schema, where: r.digest == ^digest)
  end

  defp handle_delete(_), do: :ok

  # Internal

  defp adapter do
    default = Bonfire.Notify.WebPush.HttpAdapter

    IO.inspect(vapid_keys: Application.get_env(:web_push_encryption, :vapid_details))

    adapter = Bonfire.Common.Config.get(Bonfire.Notify.WebPush)[:adapter] || default

    IO.inspect(adapter)
  end

  defp retry_timeout do
    Bonfire.Common.Config.get(Bonfire.Notify.WebPush)[:retry_timeout]
  end

  defp max_attempts do
    Bonfire.Common.Config.get(Bonfire.Notify.WebPush)[:max_attempts]
  end
end
