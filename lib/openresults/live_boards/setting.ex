defmodule OpenResults.LiveBoards.Setting do
  @moduledoc "A tournament's live-board settings. See `OpenResults.LiveBoards.delay_minutes/1`."

  use Ecto.Schema

  @primary_key {:tournament_slug, :string, autogenerate: false}
  schema "live_settings" do
    field :delay_minutes, :integer, default: 0
    field :updated_by, :string

    timestamps(type: :utc_datetime_usec)
  end
end
