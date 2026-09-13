defmodule OpenResults.Repo.Migrations.AdminSettings do
  use Ecto.Migration

  def change do
    # Server settings the operator can change from the admin panel without a
    # deploy - see `OpenResults.ServerSettings`. A missing row means "not set
    # in the panel": the environment's value, or the built-in default, is in
    # force. Kept apart from `settings`, whose rows are the two boolean
    # switches and whose `value` column is a boolean.
    #
    # `value` is text: an integer is stored as its decimal digits, a name or
    # an address as itself, and the public notice as a JSON document.
    create table(:server_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text, null: false
      add :updated_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    # Trusted installations and their own limits - see
    # `OpenResults.Moderation.trust/3` and `put_installation_limits/3`. A null
    # limit means the server-wide value applies.
    alter table(:installations) do
      add :trusted, :boolean, null: false, default: false
      add :max_tournaments, :integer
      add :max_snapshot_bytes, :integer
      add :publishes_per_minute, :integer
      add :max_versions, :integer
    end
  end
end
