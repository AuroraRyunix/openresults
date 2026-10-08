defmodule OpenResults.Repo.Migrations.CreateRelayKeys do
  use Ecto.Migration

  def change do
    # A credential for a hall relay, bound to ONE tournament and good for ONE
    # route - see `OpenResults.RelayKeys`. The slug is not a foreign key for
    # the reason `live_games.tournament_slug` is not: a takedown deletes by
    # slug, in its own transaction, and says so.
    create table(:relay_keys) do
      add :tournament_slug, :string, null: false

      # SHA-256 of the key, lowercase hex - never the key. Same argument as
      # `installations.key_hash`: 256 random bits, nothing for a work factor
      # to slow a search of.
      add :key_hash, :string, null: false

      # What the admin called it ("hall relay, upstairs"), and the last four
      # characters of the key so two rows can be told apart against the
      # label written on the box. Four characters of 43 narrow nothing.
      add :label, :string
      add :hint, :string, null: false

      add :created_by, :string, null: false
      add :revoked_at, :utc_datetime_usec
      add :revoked_by, :string

      # Written at most once a minute. No address: this is for a person
      # asking "is the box still talking", not for an audit trail.
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:relay_keys, [:key_hash])
    create index(:relay_keys, [:tournament_slug])
  end
end
