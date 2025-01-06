defmodule Bonfire.Notify.Notification do
  @moduledoc """
  The Notification schema.
  """
  alias Bonfire.Data.Identity.User

  use Ecto.Schema

  # @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary

  schema "bonfire_notify" do
    field(:state_dismissed, :boolean, read_after_writes: true)
    field(:topic, :string)
    field(:event_type, :string)
    field(:data, :map)

    belongs_to(:user, User)

    timestamps()
  end
end
