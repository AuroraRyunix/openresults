defmodule OpenResults.Repo.Migrations.AddTournamentPublisher do
  use Ecto.Migration

  @moduledoc """
  Who published a tournament, for the admin panel only - see
  `docs/snapshot-schema.md`'s `publisher` field and
  `OpenResults.Tournaments.set_publisher/2`.

  Both nullable and additive: a tournament published with the operator token
  by an older OpenPairings, or from a desktop/local install, simply never has
  these set and the admin panel keeps showing "operator", exactly as before
  this migration.
  """

  def change do
    alter table(:tournaments) do
      # The hosted account's email, from `payload["publisher"]["email"]`.
      # Personal data - never selected on any public query, see
      # `OpenResultsWeb.Tournament` and its tests.
      add :owner_email, :string
      add :owner_host, :string
    end
  end
end
