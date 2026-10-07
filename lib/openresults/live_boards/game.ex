defmodule OpenResults.LiveBoards.Game do
  @moduledoc """
  One board's game, as last reported. See `OpenResults.LiveBoards`.

  `plies` is a list of string-keyed maps, one per move played, oldest first:

    * `"san"` - the move, canonical SAN
    * `"fen"` - the position after it
    * `"from"`, `"to"` - the squares (0 = a8 .. 63 = h1), for highlighting
    * `"at"` - when the server first heard of it, ms since the epoch
    * `"w"`, `"b"`, `"r"` - the clocks reported with it (ms) and which side's
      was running (`"white"`, `"black"` or `nil`); `nil` when it arrived
      without clocks
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "live_games" do
    field :tournament_slug, :string
    field :round, :integer
    field :board, :integer
    field :start_fen, :string
    field :fen, :string
    field :ply_count, :integer, default: 0
    field :plies, {:array, :map}, default: []
    field :white_ms, :integer
    field :black_ms, :integer
    field :running, :string
    field :clock_at_ms, :integer
    field :last_from, :integer
    field :last_to, :integer
    field :last_san, :string
    field :status, :string, default: "live"
    field :result, :string
    field :started_at_ms, :integer
    field :moved_at_ms, :integer
    field :finished_at_ms, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
