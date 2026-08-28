defmodule OpenResults.Repo.Migrations.CreateTournamentKeys do
  use Ecto.Migration

  def change do
    # One row per CLAIMED slug. Not a column on `snapshots`, and the
    # distinction matters: `snapshots` appends, so a key living there would be
    # re-stated on every publish and the question "which of these eleven rows
    # holds the real key" would have to be answered by ordering. A key is a
    # fact about the SLUG, held once, and mutable exactly never.
    #
    # The table is also deliberately small. It answers one question - may this
    # request touch this tournament - and knows nothing about the tournament
    # itself. A tournament that has never been claimed simply has no row here,
    # which is what lets the whole feature ship without a backfill.
    create table(:tournament_keys) do
      add :tournament_slug, :string, null: false

      # SHA-256 of the key, lowercase hex. Never the key itself.
      #
      # A dump of this file must not confer publish rights over every
      # tournament ever published, and that is the entire requirement. It is
      # met by storing a digest whose preimage is a machine-generated random
      # value.
      #
      # Not bcrypt/argon2, and that is a decision rather than an omission.
      # Password KDFs exist to make GUESSING expensive, because humans choose
      # from a small space. This key is never typed and never chosen: the
      # arbiter's machine generates it at random, so there is no small space to
      # guess and a work factor would buy nothing while adding a dependency
      # this app does not otherwise need.
      #
      # Not salted either, for the same reason - a rainbow table over a
      # 256-bit random space does not exist. The one thing a salt would hide is
      # that two slugs share a key, which is a misconfiguration worth being
      # able to SEE rather than a secret worth keeping.
      add :key_hash, :string, null: false

      # When the slug was claimed. The only history this table keeps: a key is
      # written once and never rotated in place, so there is nothing an
      # `updated_at` could say.
      add :claimed_at, :utc_datetime_usec, null: false
    end

    # UNIQUE, and it is load-bearing rather than tidy. Trust-on-first-use is a
    # read-then-write, and two machines publishing the same new slug at the
    # same moment can both read "unclaimed". The constraint is what makes one
    # of them lose; the loser re-reads the winning row and is judged against
    # it, so the race resolves to "first publish wins" instead of "last write
    # wins". Enforcing this in application code alone would leave the window
    # open, and the window is exactly the accident this feature exists to stop.
    create unique_index(:tournament_keys, [:tournament_slug])
  end
end
