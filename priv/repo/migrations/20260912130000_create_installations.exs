defmodule OpenResults.Repo.Migrations.CreateInstallations do
  use Ecto.Migration

  def change do
    # One row per OpenPairings installation that asked this server for a key -
    # see `OpenResults.Installations` and `docs/public-publishing.md`.
    #
    # The primary key is the public identifier (`in_` and ten characters)
    # rather than an integer, because it is the one handle that appears in the
    # registration response, the admin panel and the action log alike, and a
    # second, internal id would be a second thing to translate between.
    create table(:installations, primary_key: false) do
      add :id, :string, primary_key: true

      # SHA-256 of the key, lowercase hex - never the key. The same argument as
      # `tournament_keys.key_hash`: the key is 32 random bytes, so there is no
      # small space for a work factor or a salt to protect.
      add :key_hash, :string, null: false

      # What the installation said it was. Advisory, and truncated on the way
      # in: an unauthenticated caller wrote it.
      add :client, :string
      add :client_version, :string

      add :status, :string, null: false, default: "active"

      # Client addresses, text in `:inet.ntoa/1` form. Nulled after 30 days by
      # `OpenResults.Retention` - each against its own timestamp.
      add :created_from, :string
      add :last_seen_at, :utc_datetime_usec
      add :last_seen_from, :string

      timestamps(type: :utc_datetime_usec)
    end

    # UNIQUE and indexed: every installation-key request is authenticated by
    # looking its digest up here, so this is the lookup rather than a scan.
    create unique_index(:installations, [:key_hash])
    create index(:installations, [:status])
  end
end
