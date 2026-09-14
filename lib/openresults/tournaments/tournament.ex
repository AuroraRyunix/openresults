defmodule OpenResults.Tournaments.Tournament do
  @moduledoc """
  A tournament's visibility and owner. One row per slug; see
  `OpenResults.Tournaments`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(pending listed hidden)

  schema "tournaments" do
    field :slug, :string
    field :status, :string
    field :minted_at, :utc_datetime_usec

    # Who published, from a hosted OpenPairings only - see
    # `OpenResults.Tournaments.set_publisher/2` and `docs/snapshot-schema.md`'s
    # `publisher` field. Admin panel only: never selected on any public query.
    field :owner_email, :string
    field :owner_host, :string

    belongs_to :installation, OpenResults.Installations.Installation, type: :string

    # Filled by the moderation listings; never stored.
    field :name, :string, virtual: true
    field :front_page, :integer, virtual: true
    field :last_published_at, :utc_datetime_usec, virtual: true
    field :open_reports, :integer, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The three statuses, as stored."
  def statuses, do: @statuses
end
