defmodule OpenResults.Repo.Migrations.CreateTournaments do
  use Ecto.Migration

  def up do
    # A tournament's visibility and its owner - see `OpenResults.Tournaments`.
    #
    # One row per slug, separate from `snapshots` for the reason
    # `tournament_keys` is: `snapshots` appends, so a status stored there would
    # be restated on every publish, and "which of these eleven rows says it is
    # hidden" would have to be answered by ordering.
    #
    # A slug can have a row and no snapshot - a slug minted for an installation
    # that has not published yet - and, before this migration ran, every slug
    # had snapshots and no row. The backfill below closes the second case, so
    # after it a snapshot without a row can only be a tournament the operator
    # published, and `OpenResults.Tournaments.status/1` reads a missing row as
    # `listed` for exactly that reason.
    create table(:tournaments) do
      add :slug, :string, null: false

      # `pending` | `listed` | `hidden`
      add :status, :string, null: false

      # The installation this slug was minted for. `nil` for a tournament the
      # operator token published, and for every tournament that existed
      # before public publishing did.
      add :installation_id, references(:installations, type: :string, on_delete: :nothing)

      # When the slug was minted. `nil` for the same tournaments as above;
      # `OpenResults.Retention` releases a minted slug that never published.
      add :minted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tournaments, [:slug])
    create index(:tournaments, [:installation_id, :status])
    create index(:tournaments, [:status])

    # Every tournament published before this, `listed` and owned by nobody:
    # exactly what the operator token publishes from now on, which is what
    # every one of them was.
    execute(backfill_sql(DateTime.utc_now()))
  end

  def down do
    drop table(:tournaments)
  end

  @doc false
  # Public so the backfill can be tested against a sandboxed database without
  # running the migration itself.
  def backfill_sql(%DateTime{} = now) do
    stamp = now |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    """
    INSERT INTO tournaments (slug, status, installation_id, minted_at, inserted_at, updated_at)
    SELECT DISTINCT s.tournament_slug, 'listed', NULL, NULL, '#{stamp}', '#{stamp}'
    FROM snapshots AS s
    WHERE NOT EXISTS (SELECT 1 FROM tournaments AS t WHERE t.slug = s.tournament_slug)
    """
  end
end
