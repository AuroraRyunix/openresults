defmodule OpenResults.Repo.Migrations.AddEventToTournaments do
  use Ecto.Migration

  @moduledoc """
  Which event a tournament says it is a section of, for the tab strip and the
  event page - see `OpenResults.TournamentGroups`.

    * `event_id` - `tournament.group.id` of the tournament's newest snapshot,
      written at ingest. Indexed: an event page asks "who claims this id".
    * `event_since` - when this slug started claiming that id. The publisher
      that claimed an id first is the one the event belongs to.

  Both nullable and additive. Nothing is backfilled: no snapshot stored
  before this migration carries the block.
  """

  def change do
    alter table(:tournaments) do
      add :event_id, :string
      add :event_since, :utc_datetime_usec
    end

    create index(:tournaments, [:event_id])
  end
end
