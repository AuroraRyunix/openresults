defmodule OpenResults.Snapshots.Snapshot do
  @moduledoc """
  One publish from an arbiter's machine, stored whole.

  The row is written once and never updated, so there are no `timestamps()`:
  an `updated_at` on an append-only table is a column that always equals
  another one, and `received_at` already carries the only moment that matters.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "snapshots" do
    field :tournament_slug, :string
    field :version, :integer
    field :source_app, :string
    field :source_version, :string
    field :published_at, :utc_datetime
    field :received_at, :utc_datetime_usec
    field :payload, :map
  end

  @doc false
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :tournament_slug,
      :version,
      :source_app,
      :source_version,
      :published_at,
      :received_at,
      :payload
    ])
    |> validate_required([:tournament_slug, :version, :received_at, :payload])
  end
end
