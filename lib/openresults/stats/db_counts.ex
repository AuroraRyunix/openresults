defmodule OpenResults.Stats.DbCounts do
  @moduledoc """
  Row counts and file sizes for the stats page's database section.

  Counting the snapshot table walks it, so `OpenResults.Stats.Collector`
  runs `read/0` on a timer, off the request path and outside its own
  process, and the page shows the last result with the time it was taken.
  """

  import Ecto.Query

  alias OpenResults.Installations.Installation
  alias OpenResults.Registrations.Registration
  alias OpenResults.Repo
  alias OpenResults.Reports.Report
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.Tournaments.Tournament

  @doc "Every count the page shows. Raises when the database cannot be read."
  @spec read() :: map()
  def read do
    %{
      tournaments: by_status(Tournament, ~w(pending listed hidden)),
      snapshots: Repo.aggregate(Snapshot, :count),
      installations: by_status(Installation, ~w(active suspended revoked)),
      registrations: Repo.aggregate(Registration, :count),
      reports: by_status(Report, ~w(open resolved))
    }
  end

  defp by_status(schema, statuses) do
    stored =
      from(x in schema, group_by: x.status, select: {x.status, count()})
      |> Repo.all()
      |> Map.new()

    # Every expected status in order, then anything else the table holds.
    Enum.map(statuses, &{&1, Map.get(stored, &1, 0)}) ++
      Enum.sort(Map.to_list(Map.drop(stored, statuses)))
  end

  @doc """
  The SQLite database file and its write-ahead log, in bytes, from the file
  system - `nil` for one that does not exist (no WAL between checkpoints is
  normal).
  """
  @spec files() :: %{
          path: String.t(),
          database_bytes: integer() | nil,
          wal_bytes: integer() | nil
        }
  def files do
    path =
      (Application.get_env(:openresults, Repo)[:database] || "openresults.db") |> Path.expand()

    %{path: path, database_bytes: size(path), wal_bytes: size(path <> "-wal")}
  end

  defp size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> nil
    end
  end
end
