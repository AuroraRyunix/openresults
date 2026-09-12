defmodule OpenResults.Installations.Installation do
  @moduledoc """
  One OpenPairings installation holding an installation key. See
  `OpenResults.Installations`.

  `key_hash` is a digest; the key itself is never stored, logged or returned
  after the registration response that created it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(active suspended revoked)

  @primary_key {:id, :string, autogenerate: false}
  schema "installations" do
    field :key_hash, :string, redact: true
    field :client, :string
    field :client_version, :string
    field :status, :string, default: "active"
    field :created_from, :string
    field :last_seen_at, :utc_datetime_usec
    field :last_seen_from, :string

    # Filled by `OpenResults.Installations.list/1`; never stored.
    field :tournament_count, :integer, virtual: true

    has_many :tournaments, OpenResults.Tournaments.Tournament

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The three statuses, as stored."
  def statuses, do: @statuses

  @doc false
  def create_changeset(installation, attrs) do
    installation
    |> cast(attrs, [:id, :key_hash, :client, :client_version, :created_from])
    |> validate_required([:id, :key_hash])
    |> put_change(:status, "active")
    |> unique_constraint(:key_hash)
  end
end
