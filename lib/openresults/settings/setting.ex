defmodule OpenResults.Settings.Setting do
  @moduledoc "One runtime switch. See `OpenResults.Settings`."

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :boolean
    field :updated_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:value, :updated_by])
    |> validate_required([:value])
  end
end
