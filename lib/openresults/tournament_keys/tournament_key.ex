defmodule OpenResults.TournamentKeys.TournamentKey do
  @moduledoc """
  The claim one arbiter's machine holds over one slug.

  Written once, when a slug is first published with a key, and never updated:
  there is no rotation path and no `updated_at`, because a key that could be
  replaced by whoever currently holds the slug would be a takeover with extra
  steps. Losing a key is recovered through break-glass, not through rotation.

  `key_hash` is a digest. The key itself is never stored, never logged, and
  never returned by any route.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "tournament_keys" do
    field :tournament_slug, :string
    field :key_hash, :string
    field :claimed_at, :utc_datetime_usec
  end

  @doc false
  def changeset(tournament_key, attrs) do
    tournament_key
    |> cast(attrs, [:tournament_slug, :key_hash, :claimed_at])
    |> validate_required([:tournament_slug, :key_hash, :claimed_at])
    |> unique_constraint(:tournament_slug)
  end
end
