defmodule OpenResults.Repo.Migrations.CreateSnapshots do
  use Ecto.Migration

  def change do
    # APPEND, NOT REPLACE. Every publish gets its own row and nothing is ever
    # updated in place, so there is no unique index on the slug.
    #
    # The reasoning, in the order it mattered:
    #
    # 1. A published round is immutable, so a later snapshot never contradicts
    #    an earlier one about a round they share - it only adds rounds. Two
    #    rows for one slug are therefore two consistent views of the same
    #    tournament at different moments, not a stale row and a fresh one.
    # 2. Standings are the part that legitimately moves, and "what did the
    #    standings say at 14:00" is a question an arbiter gets asked after a
    #    disputed result. Replacing throws that answer away permanently; the
    #    contract forbids recomputing it, so if the row is gone it is gone.
    # 3. The volume does not justify the loss. An arbiter republishes once per
    #    round - eleven rows for a nine-rounder, a few hundred kilobytes each.
    #
    # Cost of appending: reads must order rather than fetch by key, which the
    # composite index below covers.
    create table(:snapshots) do
      add :tournament_slug, :string, null: false
      add :version, :integer, null: false

      # From the envelope's `source` object. Real columns because "which
      # OpenPairings version produced this" is the first question asked when a
      # payload looks wrong, and digging it out of the blob for every row of a
      # diagnostic query is miserable.
      add :source_app, :string
      add :source_version, :string

      # The arbiter's clock, from the envelope. Advisory: a laptop in a
      # playing hall may have any time at all on it.
      add :published_at, :utc_datetime

      # The server's clock. Authoritative, and the ordering key - microsecond
      # precision so two publishes in the same second still order, with the id
      # as final tie-break.
      add :received_at, :utc_datetime_usec, null: false

      # The document, whole and uninterpreted. Shredding rounds and boards into
      # tables would turn every additive field in the contract into a
      # migration, which is the one thing the contract is designed to avoid.
      add :payload, :map, null: false
    end

    # Slug first, so this index also serves a bare lookup by slug; received_at
    # second so the newest row for a slug is the end of a range scan. A
    # separate single-column index on the slug would be a redundant prefix.
    #
    # SQLite has no date type and stores the timestamp as ISO 8601 text, which
    # is why this works: the format is fixed-width UTC with six fractional
    # digits, so byte order and chronological order are the same and the index
    # answers "newest" and "at or before" without reading rows.
    create index(:snapshots, [:tournament_slug, :received_at])
  end
end
