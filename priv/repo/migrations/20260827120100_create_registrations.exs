defmodule OpenResults.Repo.Migrations.CreateRegistrations do
  use Ecto.Migration

  def change do
    # The payload travelling the other way. This table only accepts and holds:
    # the arbiter's machine pulls, and the arbiter decides. Nothing here ever
    # writes to a tournament, and no snapshot ever reads from here.
    create table(:registrations) do
      add :tournament_slug, :string, null: false
      add :version, :integer, null: false

      # The server's clock, not the `received_at` the form put in the envelope.
      # That one is a claim by an unauthenticated public submitter; this one is
      # the fact. The claim survives untouched inside the payload.
      add :received_at, :utc_datetime_usec, null: false

      # Holds the one piece of personal data in the system - the player's
      # email, so the arbiter can reach them. It is never part of a snapshot
      # and never rendered.
      add :payload, :map, null: false
    end

    create index(:registrations, [:tournament_slug, :received_at])
  end
end
