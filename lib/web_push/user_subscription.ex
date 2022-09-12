defmodule Bonfire.Notify.WebPush.UserSubscription do
  @moduledoc """
  The subscription schema.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "bonfire_web_push_subscription" do
    field(:user_id, :binary)
    field(:digest, :string)
    field(:data, :string)

    timestamps()
  end
end
