defmodule Mix.Tasks.Openresults.LiveSeed do
  @shortdoc "Publishes a demo tournament (live-demo) for the live-boards pages"

  @moduledoc """
  Dev only. Publishes round 1 of the Swiss contract fixture as the tournament
  `live-demo`, with boards 1 to 3 still undecided, so that
  `mix openresults.live_sim --slug live-demo` has boards to put moves on.

      mix openresults.live_seed
      mix openresults.live_seed --slug other-demo

  Creates and migrates the dev database if it is not there yet, and can be run
  again: a repeat publishes the same document again. The ingest token is the
  fixed one from `config/dev.exs`; the tournament is not claimed, so no
  tournament key is needed.
  """

  use Mix.Task

  @fixture "test/fixtures/snapshot_swiss.json"

  @impl Mix.Task
  def run(args) do
    unless Mix.env() in [:dev, :test], do: Mix.raise("dev only")

    {opts, _, invalid} = OptionParser.parse(args, strict: [slug: :string])
    if invalid != [], do: Mix.raise("unknown option: #{inspect(invalid)}")
    slug = opts[:slug] || "live-demo"

    Logger.configure(level: :info)
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start")

    payload = payload(slug)

    case OpenResults.Snapshots.ingest(payload) do
      {:ok, _snapshot} ->
        Mix.shell().info("""
        published #{slug}: #{length(hd(payload["rounds"])["boards"])} boards in round 1

        token: #{Application.get_env(:openresults, :ingest_token)}
        key:   (none, the tournament is not claimed)

        http://localhost:4005/t/#{slug}/live
        """)

      {:error, reason} ->
        Mix.raise("publish failed: #{inspect(reason)}")
    end
  end

  defp payload(slug) do
    doc = @fixture |> File.read!() |> Jason.decode!()

    round1 =
      doc["rounds"]
      |> hd()
      |> Map.update!("boards", fn boards ->
        Enum.map(boards, fn
          %{"board" => n} = board when n in 1..3 ->
            board |> Map.delete("points") |> Map.put("result", nil)

          board ->
            board
        end)
      end)

    doc
    |> put_in(["tournament", "slug"], slug)
    |> Map.put("rounds", [round1])
    |> Map.put(
      "published_at",
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )
  end
end
