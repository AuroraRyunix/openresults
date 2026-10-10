defmodule OpenResults.LiveBoards.Simulator do
  @moduledoc """
  Plays PGN games into the live-boards ingest API as a hall relay would: one
  update per move with the moves so far and both clocks, then the result.
  For development and demonstrations - `mix openresults.live_sim`.

  `plan/2` turns a game into the list of `{wait_ms, body}` the relay would
  send; `run/2` sends them over HTTP, one task per game. The two are apart so
  the plan can be tested without a server and without waiting.

  ## Time

  `speed` scales wall time: at 30, a move that took the player 60 seconds
  takes 2. The clocks scale with it - a 90-minute control reads as 3 minutes -
  so that the clock a spectator sees counts down at the pace the moves
  arrive, instead of jumping at every move. A game that carries `[%clk]`
  comments uses its own times; any other gets a seeded pseudo-random think
  time of 3 to 90 seconds a move.
  """

  alias OpenResults.LiveBoards.PgnReader

  @defaults [
    speed: 30.0,
    clock: 5400,
    increment: 30,
    seed: 1,
    round: 1,
    first_board: 1
  ]

  @doc "The options and their defaults."
  def defaults, do: @defaults

  @doc "Reads every game in the given PGN files, in order."
  @spec load([Path.t()]) :: [map()]
  def load(paths), do: Enum.flat_map(paths, &(&1 |> File.read!() |> PgnReader.parse()))

  @doc """
  The updates for one game on board `board`: `[{wait_ms, body}]`, where
  `wait_ms` is how long to wait before sending `body`.
  """
  @spec plan(map(), keyword()) :: [{non_neg_integer(), map()}]
  def plan(game, opts) do
    opts = Keyword.merge(@defaults, opts)
    speed = opts[:speed]
    board = Keyword.fetch!(opts, :board)
    scale = fn game_ms -> round(game_ms / speed) end

    initial = scale.(opts[:clock] * 1000)
    increment = scale.(opts[:increment] * 1000)
    :rand.seed(:exsss, {opts[:seed], board, 7})

    base = %{"round" => opts[:round], "board" => board}

    start =
      {0,
       Map.merge(base, %{
         "moves" => [],
         "white_ms" => initial,
         "black_ms" => initial,
         "running" => "white",
         # A rerun starts the game over instead of being ignored as older.
         "replace" => true
       })}

    {updates, _clocks} =
      game.moves
      |> Enum.with_index(1)
      |> Enum.map_reduce({initial, initial}, fn {_san, ply}, {white, black} ->
        mover = if rem(ply, 2) == 1, do: :white, else: :black
        remaining = if mover == :white, do: white, else: black
        think = think_ms(game, ply, remaining, speed)
        after_move = max(remaining - think, 0) + increment
        {white, black} = if mover == :white, do: {after_move, black}, else: {white, after_move}

        body =
          Map.merge(base, %{
            "moves" => Enum.take(game.moves, ply),
            "white_ms" => white,
            "black_ms" => black,
            "running" => if(mover == :white, do: "black", else: "white")
          })

        {{think, body}, {white, black}}
      end)

    final = List.last(updates) |> elem(1)

    finish =
      {400,
       Map.merge(final, %{"status" => "finished", "result" => game.result, "running" => "none"})}

    [start | updates] ++ [finish]
  end

  # Wall time to the move: the player's own clock when the game has one
  # (`[%clk]` after this move and after their previous one), else a draw.
  defp think_ms(game, ply, remaining, speed) do
    own = Enum.at(game.clocks, ply - 1)
    previous = if ply > 2, do: Enum.at(game.clocks, ply - 3)

    game_ms =
      if own && previous,
        do: max(previous - own, 1_000),
        else: 3_000 + trunc(:rand.uniform() * 87_000)

    min(round(game_ms / speed), max(remaining - 1, 0)) |> max(300)
  end

  @doc """
  Sends every game's plan to `url`, one task per game, and returns once the
  last has finished. Options: `:url`, `:slug`, `:token`, `:key` (the
  tournament key, when the slug is claimed), `:req` (extra `Req` options -
  the tests' stub), plus those `plan/2` takes. `log` is called with each
  line of progress.
  """
  @spec run([map()], keyword(), (String.t() -> any())) :: :ok | {:error, term()}
  def run(games, opts, log \\ fn _line -> :ok end) do
    first = Keyword.get(opts, :first_board, @defaults[:first_board])

    games
    |> Enum.with_index(first)
    |> Task.async_stream(
      fn {game, board} -> play(game, Keyword.put(opts, :board, board), log) end,
      timeout: :infinity,
      max_concurrency: max(length(games), 1)
    )
    |> Enum.reduce(:ok, fn
      {:ok, :ok}, acc -> acc
      {:ok, {:error, reason}}, _acc -> {:error, reason}
      {:exit, reason}, _acc -> {:error, reason}
    end)
  end

  defp play(game, opts, log) do
    name = fn colour -> Map.get(game.headers, colour, "?") end
    log.("board #{opts[:board]}: #{name.("White")} - #{name.("Black")}")

    game
    |> plan(opts)
    |> Enum.reduce_while(:ok, fn {wait, body}, :ok ->
      Process.sleep(wait)

      case post(body, opts) do
        :ok ->
          log.("board #{opts[:board]}: ply #{length(body["moves"])}#{finished_note(body)}")
          {:cont, :ok}

        {:error, reason} ->
          log.("board #{opts[:board]}: refused: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  end

  defp finished_note(%{"status" => "finished", "result" => result}), do: ", finished #{result}"
  defp finished_note(_body), do: ""

  defp post(body, opts) do
    url = String.trim_trailing(Keyword.fetch!(opts, :url), "/")
    endpoint = "#{url}/api/tournaments/#{Keyword.fetch!(opts, :slug)}/live"

    headers =
      case Keyword.get(opts, :key) do
        nil -> []
        key -> [{"x-openresults-key", key}]
      end

    request =
      Keyword.merge(
        [
          json: body,
          auth: {:bearer, Keyword.fetch!(opts, :token)},
          headers: headers,
          retry: false
        ],
        Keyword.get(opts, :req, [])
      )

    case Req.post(endpoint, request) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: reply}} -> {:error, {status, reply}}
      {:error, reason} -> {:error, reason}
    end
  end
end
