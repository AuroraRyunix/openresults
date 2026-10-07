defmodule Mix.Tasks.Openresults.LiveSim do
  @shortdoc "Replays PGN games into the live-boards ingest API"

  @moduledoc """
  Feeds the live-boards API from PGN files, the way a hall relay will: one
  update per move with both clocks, then the result. For development and
  demonstrations; nothing here is used in production.

      mix openresults.live_sim --slug my-open --token $OPENRESULTS_INGEST_TOKEN

  Plays the three games in `priv/live_sim` on boards 1 to 3 of round 1 of
  the tournament `--slug` against `http://localhost:4000`. The tournament must
  already be published (the arbiter's snapshot says who sits on the boards;
  a board the snapshot does not list shows nothing to spectators).

  ## Options

    * `--slug` - the tournament (required)
    * `--url` - the server, default `http://localhost:4000`
    * `--token` - the ingest token, default `$OPENRESULTS_INGEST_TOKEN`
    * `--key` - the tournament key if it has been claimed, default
      `$OPENRESULTS_TOURNAMENT_KEY`
    * `--round` - default 1; `--first-board` - the board of the first game,
      default 1, each further game takes the next
    * `--speed` - how much faster than real time, default 30. Clocks scale with
      it: at 30 a 90-minute control reads 3 minutes
    * `--clock` and `--increment` - the control in seconds, default 5400 and 30
    * `--seed` - the seed of the think times, default 1
    * `--dry-run` - print the first updates of each game and send nothing

  Any other arguments are PGN files; with none, the fixtures in
  `priv/live_sim`.
  """

  use Mix.Task

  alias OpenResults.LiveBoards.Simulator

  @switches [
    slug: :string,
    url: :string,
    token: :string,
    key: :string,
    round: :integer,
    first_board: :integer,
    speed: :float,
    clock: :integer,
    increment: :integer,
    seed: :integer,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, files, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("unknown option: #{inspect(invalid)}")
    slug = opts[:slug] || Mix.raise("--slug is required")

    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)

    files = if files == [], do: fixtures(), else: files
    games = Simulator.load(files)
    if games == [], do: Mix.raise("no games found in #{inspect(files)}")

    sim_opts =
      opts
      |> Keyword.take([:round, :first_board, :speed, :clock, :increment, :seed])
      |> Keyword.merge(
        url: opts[:url] || "http://localhost:4000",
        slug: slug,
        token: opts[:token] || System.get_env("OPENRESULTS_INGEST_TOKEN") || "",
        key: opts[:key] || System.get_env("OPENRESULTS_TOURNAMENT_KEY")
      )

    if opts[:dry_run], do: dry_run(games, sim_opts), else: send_all(games, sim_opts)
  end

  defp fixtures do
    :openresults |> Application.app_dir("priv/live_sim") |> Path.join("*.pgn") |> Path.wildcard()
  end

  defp send_all(games, opts) do
    if opts[:token] == "",
      do: Mix.raise("no ingest token: pass --token or set OPENRESULTS_INGEST_TOKEN")

    case Simulator.run(games, opts, fn line -> Mix.shell().info(line) end) do
      :ok -> Mix.shell().info("done")
      {:error, reason} -> Mix.raise("stopped: #{inspect(reason)}")
    end
  end

  defp dry_run(games, opts) do
    first = Keyword.get(opts, :first_board, 1)

    for {game, board} <- Enum.with_index(games, first) do
      Mix.shell().info("board #{board}: #{game.headers["White"]} - #{game.headers["Black"]}")

      for {wait, body} <- game |> Simulator.plan(Keyword.put(opts, :board, board)) |> Enum.take(4) do
        Mix.shell().info("  after #{wait} ms: #{Jason.encode!(body)}")
      end
    end

    :ok
  end
end
