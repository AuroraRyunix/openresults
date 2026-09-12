defmodule OpenResults.Repo.Migrations.CreateModeration do
  use Ecto.Migration

  def change do
    # What the public reports about a tournament page - see
    # `OpenResults.Reports`. Kept through a takedown: a report is a moderation
    # record about a page, not the page's data.
    create table(:reports) do
      add :tournament_slug, :string, null: false
      add :reason, :string, null: false
      add :details, :text
      add :contact_email, :string

      # Nulled after 30 days by `OpenResults.Retention`.
      add :client_address, :string

      # `open` | `resolved`
      add :status, :string, null: false, default: "open"
      add :resolution, :text
      add :resolved_by, :string
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:reports, [:tournament_slug, :status])
    create index(:reports, [:status, :inserted_at])

    # A single address or a CIDR range, always expiring - see
    # `OpenResults.AddressBlocks`.
    create table(:address_blocks) do
      # Canonical text: the network address and the prefix length.
      add :cidr, :string, null: false
      add :reason, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :created_by, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:address_blocks, [:expires_at])

    # The runtime switches the admin panel flips without a restart. A missing
    # row is the documented default - see `OpenResults.Settings`.
    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :boolean, null: false
      add :updated_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    # Who did what to which target, and when. Append-only: nothing updates or
    # deletes a row here.
    create table(:moderation_actions) do
      # An admin's email, `break-glass`, or `retention`.
      add :actor, :string, null: false
      add :action, :string, null: false
      add :target_type, :string
      add :target, :string
      add :details, :map

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:moderation_actions, [:inserted_at])
    create index(:moderation_actions, [:target_type, :target])
  end
end
