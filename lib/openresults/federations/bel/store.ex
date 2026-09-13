defmodule OpenResults.Federations.BEL.Store do
  @moduledoc """
  The reduced Belgian roster this server hands out at
  `GET /api/federations/bel/players`, and the only place that writes it.

  ## Never a half-written sync

  `put/1` writes the new export's JSON to a temp file beside the real one
  and renames it over the real one - a rename is atomic on both the
  filesystems this app ships on, so a request either sees the old file or
  the new one, never a partial one. The in-memory copy this module actually
  serves from (an ETS table, so a request never touches disk) is only
  swapped in after that rename succeeds, for the same reason.

  ## What is kept

  `updated_at`, the player count, and the already-gzipped JSON body plus its
  ETag - built once, at write time, rather than on every request. `last_
  error` and `last_attempt_at` are kept for the admin panel only: they are
  not persisted to disk and do not survive a restart, which is fine, since
  the next sync attempt (at boot, if the disk copy is stale, or on the next
  scheduled run) overwrites them within a day.
  """

  use GenServer

  require Logger

  @table __MODULE__

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Where the reduced roster is persisted between restarts."
  def path do
    Application.get_env(:openresults, :bel_store_path) ||
      Path.join([:code.priv_dir(:openresults), "bel", "players.json"])
  end

  @doc """
  Records a successful sync: `rows` already reduced through `Fields.reduce/1`.
  Writes the file (temp + rename) and swaps in the in-memory copy. Returns
  `:ok` or `{:error, reason}` if the file could not be written.
  """
  @spec put([map()]) :: :ok | {:error, term()}
  def put(rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    body =
      Jason.encode!(%{updated_at: DateTime.to_iso8601(now), count: length(rows), players: rows})

    with :ok <- write_atomically(path(), body) do
      gzip = :zlib.gzip(body)

      etag =
        ~s("#{:crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 32)}")

      GenServer.call(
        __MODULE__,
        {:put, %{updated_at: now, count: length(rows), body: body, gzip: gzip, etag: etag}}
      )
    end
  end

  @doc "Records a failed sync attempt, for the admin panel. Leaves the served roster untouched."
  @spec put_error(String.t()) :: :ok
  def put_error(message) when is_binary(message) do
    GenServer.call(__MODULE__, {:put_error, message})
  end

  @doc """
  The current roster to serve: `{:ok, %{updated_at:, count:, body:, gzip:,
  etag:}}`, or `:none` if nothing has ever synced successfully (in this run
  or a previous one, if the disk copy loaded at boot).
  """
  @spec current() :: {:ok, map()} | :none
  def current do
    case safe_lookup(:current) do
      [{:current, data}] -> {:ok, data}
      _ -> :none
    end
  end

  @doc false
  # For tests only: forgets the in-memory copy (not the file on disk), so a
  # test can start from ":none" without depending on test order against this
  # node-wide singleton.
  def reset_for_test do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Status for the admin panel: `%{updated_at:, count:, last_error:, last_attempt_at:}`."
  @spec stats() :: map()
  def stats do
    current =
      case current() do
        {:ok, %{updated_at: at, count: count}} -> %{updated_at: at, count: count}
        :none -> %{updated_at: nil, count: 0}
      end

    error =
      case safe_lookup(:error) do
        [{:error, %{message: message, at: at}}] -> %{last_error: message, last_error_at: at}
        _ -> %{last_error: nil, last_error_at: nil}
      end

    Map.merge(current, error)
  end

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    load_from_disk()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, data}, _from, state) do
    :ets.insert(@table, {:current, data})
    :ets.delete(@table, :error)
    {:reply, :ok, state}
  end

  def handle_call({:put_error, message}, _from, state) do
    :ets.insert(@table, {:error, %{message: message, at: DateTime.utc_now()}})
    {:reply, :ok, state}
  end

  defp load_from_disk do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"updated_at" => at, "count" => count}} <- Jason.decode(body),
         {:ok, updated_at, _} <- DateTime.from_iso8601(at) do
      gzip = :zlib.gzip(body)

      etag =
        ~s("#{:crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 32)}")

      :ets.insert(
        @table,
        {:current, %{updated_at: updated_at, count: count, body: body, gzip: gzip, etag: etag}}
      )
    else
      _absent_or_unreadable -> :ok
    end
  end

  defp write_atomically(path, body) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(tmp)
        Logger.error("BEL roster store: could not write #{path}: #{inspect(reason)}")
        error
    end
  end
end
