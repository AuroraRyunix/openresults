defmodule OpenResults.Repo.Migrations.CreateLiveBoards do
  use Ecto.Migration

  @moduledoc """
  Live boards: the game on each board of a round, move by move, as a hall
  relay reports it - see `OpenResults.LiveBoards`.

  One row per (tournament, round, board). The move list lives on the row as a
  JSON array, one entry per ply, because a game is read whole and written
  whole-ish and nothing ever asks "every ply 14 across games". Times are
  integer milliseconds since the epoch: the delay arithmetic is subtraction
  and nothing else.
  """

  def change do
    create table(:live_games) do
      add :tournament_slug, :string, null: false
      add :round, :integer, null: false
      add :board, :integer, null: false

      # The position the moves start from; null is the standard one.
      add :start_fen, :string
      # The current position and how many plies lead to it. `ply_count` can
      # exceed the length of `plies` only for a game reported by FEN alone.
      add :fen, :string, null: false
      add :ply_count, :integer, null: false, default: 0
      add :plies, {:array, :map}, null: false, default: []

      # The clocks as last reported, and when. `running` is "white", "black"
      # or null.
      add :white_ms, :integer
      add :black_ms, :integer
      add :running, :string
      add :clock_at_ms, :bigint

      # The last move, kept beside the position so that a round's worth of
      # tiles is read without reading a round's worth of move lists.
      add :last_from, :integer
      add :last_to, :integer
      add :last_san, :string

      add :status, :string, null: false, default: "live"
      add :result, :string
      add :started_at_ms, :bigint, null: false
      # When the position last changed - a move, or a FEN. Not a clock tick.
      add :moved_at_ms, :bigint, null: false
      add :finished_at_ms, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:live_games, [:tournament_slug, :round, :board])

    # The broadcast delay, per tournament. Absent row means no delay.
    create table(:live_settings, primary_key: false) do
      add :tournament_slug, :string, primary_key: true
      add :delay_minutes, :integer, null: false, default: 0
      add :updated_by, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
