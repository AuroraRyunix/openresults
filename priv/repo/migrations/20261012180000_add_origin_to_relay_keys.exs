defmodule OpenResults.Repo.Migrations.AddOriginToRelayKeys do
  use Ecto.Migration

  def change do
    # Who made the key: "admin" (the panel, as every key so far) or
    # "publisher" (the tournament's own publisher, over
    # `POST /api/tournaments/:slug/relay-keys`). A column and not a reading of
    # `created_by`, because the publisher's keys are rotated by label and an
    # admin must be able to give a key any label without it being rotated away.
    alter table(:relay_keys) do
      add :origin, :string, null: false, default: "admin"
    end
  end
end
