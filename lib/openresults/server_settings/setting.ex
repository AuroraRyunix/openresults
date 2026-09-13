defmodule OpenResults.ServerSettings.Setting do
  @moduledoc "One server setting saved in the admin panel. See `OpenResults.ServerSettings`."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:key, :string, autogenerate: false}
  schema "server_settings" do
    field :value, :string
    field :updated_by, :string

    timestamps(type: :utc_datetime_usec)
  end
end
