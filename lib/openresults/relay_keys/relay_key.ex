defmodule OpenResults.RelayKeys.RelayKey do
  @moduledoc """
  One relay key. See `OpenResults.RelayKeys`.

  `key_hash` is a digest; the key itself is never stored, logged or returned
  after the creation page that showed it.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "relay_keys" do
    field :tournament_slug, :string
    field :key_hash, :string, redact: true
    field :label, :string
    field :hint, :string
    field :created_by, :string
    field :revoked_at, :utc_datetime_usec
    field :revoked_by, :string
    field :last_used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
