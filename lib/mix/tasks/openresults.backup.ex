defmodule Mix.Tasks.Openresults.Backup do
  @shortdoc "Write a backup now, list them, verify one, or recover one"

  @moduledoc """
  Backups, from the command line.

      mix openresults.backup              # write one now
      mix openresults.backup --list       # what is on disk
      mix openresults.backup --verify F   # open F and say what is in it
      mix openresults.backup --restore F  # recover F beside the live database

  The scheduler writes one a day by itself; this is for taking one before a
  risky change, and for the half that matters - getting the data back.

  `--restore` deliberately does not swap the live file. A SQLite database
  cannot be replaced underneath an open connection pool without risking the
  very thing being recovered, so it writes the recovered copy beside it and
  prints the three commands.
  """
  use Mix.Task

  alias OpenResults.Backup

  @requirements ["app.config"]

  # `app.config` and nothing more. The backup opens its own SQLite connection
  # rather than going through the Repo, so it needs configuration and not a
  # running application - and starting one here would put a second web endpoint
  # up against the port the live service is already bound to.
  @impl Mix.Task
  def run(argv) do
    case argv do
      ["--list"] -> list()
      ["--verify", path] -> verify(path)
      ["--restore", path] -> restore(path)
      [] -> create()
      _ -> Mix.raise("usage: mix openresults.backup [--list | --verify FILE | --restore FILE]")
    end
  end

  defp create do
    case Backup.create() do
      {:ok, path} ->
        size = File.stat!(path).size

        Mix.shell().info([
          :green,
          "Wrote ",
          :reset,
          path,
          " (#{human(size)}#{if Backup.encrypted?(), do: ", encrypted", else: ""})"
        ])

        case Backup.prune() do
          0 -> :ok
          n -> Mix.shell().info("Removed #{n} older backup(s), keeping #{Backup.retention()}.")
        end

      {:error, reason} ->
        Mix.raise("Backup failed: " <> reason)
    end
  end

  defp list do
    case Backup.list() do
      [] ->
        Mix.shell().info("No backups in #{Backup.directory()}.")

      backups ->
        Mix.shell().info("#{length(backups)} in #{Backup.directory()}, newest first:
")

        for b <- backups do
          Mix.shell().info(
            "  #{DateTime.to_string(b.created_at)}  #{String.pad_leading(human(b.size), 9)}" <>
              "#{if b.encrypted, do: "  encrypted", else: ""}  #{Path.basename(b.path)}"
          )
        end
    end
  end

  defp verify(path) do
    case Backup.verify(path) do
      {:ok, info} ->
        Mix.shell().info([:green, "Readable. ", :reset, describe(info)])

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp restore(path) do
    case Backup.restore(path) do
      {:ok, target} ->
        Mix.shell().info([:green, "Recovered to ", :reset, target, "
"])
        Mix.shell().info("The live database has NOT been touched. To swap it in:
")
        Mix.shell().info("  systemctl stop openresults")
        Mix.shell().info("  mv #{live()} #{live()}.before-restore")
        Mix.shell().info("  mv #{target} #{live()}")
        Mix.shell().info("  systemctl start openresults
")
        Mix.shell().info("Keep the .before-restore copy until you are sure.")

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp live, do: Application.get_env(:openresults, OpenResults.Repo)[:database]

  defp human(bytes) when bytes > 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp human(bytes) when bytes > 1_000, do: "#{div(bytes, 1_000)} kB"
  defp human(bytes), do: "#{bytes} B"

  defp describe(info), do: "#{info.snapshots} snapshot(s), #{length(info.tables)} tables."
end
