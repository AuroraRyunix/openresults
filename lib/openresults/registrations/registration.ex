defmodule OpenResults.Registrations.Registration do
  @moduledoc """
  One entry submitted from the public form, held until the arbiter pulls it.

  Nothing in this row is authoritative. A registration is a request; the
  arbiter's machine decides whether it becomes a player.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "registrations" do
    field :tournament_slug, :string
    field :version, :integer
    field :received_at, :utc_datetime_usec
    field :payload, :map
  end

  @doc false
  def changeset(registration, attrs) do
    registration
    |> cast(attrs, [:tournament_slug, :version, :received_at, :payload])
    |> validate_required([:tournament_slug, :version, :received_at, :payload])
  end
end
