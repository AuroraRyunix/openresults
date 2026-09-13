defmodule OpenResults.DiskSpace do
  @moduledoc """
  Free space on the volume holding the database, measured on a timer and
  kept in ETS, so the one question a request asks - "is this server below
  its free-disk floor?" - costs a lookup. `docs/public-publishing.md`,
  "Storage bounds".

  ## How it is measured

  `df -P -k <the database's directory>`: the POSIX output format, one line
  per filesystem, in 1024-byte blocks. Free space is **Available** - what a
  service that is not root can still write, reserved blocks left out - as a
  share of the volume's size. `df` given a path answers for the filesystem
  holding it, so there is no mount-point matching to get wrong.

  Chosen over OTP's `:os_mon`/`disksup`, which would start CPU and memory
  monitors and their alarms beside it on a small shared box, and which on
  Linux runs `df` underneath anyway.

  ## When it cannot measure

  No `df` (Windows), output that does not parse, a `df` that has not
  answered in five seconds, a reader that raised: the reading is
  `:unknown`, and **unknown allows publishing**. Refusing every arbiter
  because the server could not measure its own disk would be the wrong way
  round. A warning is logged when a measurement first fails, not every
  minute.

  ## Tests

  The reader is `config :openresults, :disk_space_reader` - `{module, fun}`
  or a one-argument function of the directory, answering
  `{:ok, %{total_bytes: n, available_bytes: n}}` or `{:error, reason}`.
  `refresh/0` measures now. The floor itself is read from configuration at
  check time, not cached, so moving it takes effect without a measurement.
  """

  use GenServer

  require Logger

  alias OpenResults.PublicPublishing

  @table __MODULE__
  @timeout 5_000
  @unmeasured "not measured in this environment"

  @type reading :: %{
          status: :ok | :low | :unknown,
          free_percent: float() | nil,
          available_bytes: non_neg_integer() | nil,
          total_bytes: pos_integer() | nil,
          floor_percent: 0..100,
          path: String.t(),
          measured_at: DateTime.t() | nil,
          error: String.t() | nil
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether installation keys must be refused `storage_low` right now."
  @spec low?() :: boolean()
  def low?, do: reading().status == :low

  @doc "The cached measurement, judged against the floor in force now."
  @spec reading() :: reading()
  def reading do
    measured =
      try do
        case :ets.lookup(@table, :measurement) do
          [{:measurement, m}] -> m
          [] -> nil
        end
      rescue
        ArgumentError -> nil
      end

    judge(measured || %{result: {:error, "not measured yet"}, at: nil, path: path()})
  end

  @doc "Measures now and caches it. For tests, and returns the reading."
  @spec refresh() :: reading()
  def refresh do
    GenServer.call(__MODULE__, :refresh, @timeout * 2)
    reading()
  end

  defp judge(%{result: result, at: at, path: path}) do
    floor = PublicPublishing.min_free_disk_percent()
    base = %{floor_percent: floor, path: path, measured_at: at}

    case result do
      {:ok, %{total_bytes: total, available_bytes: available}} ->
        percent = available * 100 / total

        Map.merge(base, %{
          status: if(floor > 0 and percent < floor, do: :low, else: :ok),
          free_percent: percent,
          available_bytes: available,
          total_bytes: total,
          error: nil
        })

      {:error, reason} ->
        Map.merge(base, %{
          status: :unknown,
          free_percent: nil,
          available_bytes: nil,
          total_bytes: nil,
          error: reason
        })
    end
  end

  @doc "The directory measured: the database's."
  def path do
    database = Application.get_env(:openresults, OpenResults.Repo)[:database] || "openresults.db"
    database |> Path.expand() |> Path.dirname()
  end

  ## ---------- readers ----------

  @doc "The production reader: `df -P -k` on `dir`."
  def df(dir) do
    case System.find_executable("df") do
      nil ->
        {:error, "no df on this system"}

      exe ->
        case System.cmd(exe, ["-P", "-k", dir], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
          {output, 0} -> parse_df(output)
          {output, status} -> {:error, "df exited #{status}: #{String.slice(output, 0, 200)}"}
        end
    end
  end

  @doc "A reader that never measures - the test environment's default."
  def unmeasured(_dir), do: {:error, @unmeasured}

  @doc """
  Reads `df -P -k` output. The four numbers are anchored between the
  filesystem name and the mount point, either of which may contain spaces.
  """
  def parse_df(output) when is_binary(output) do
    line = output |> String.split("\n", trim: true) |> Enum.at(1)

    with line when is_binary(line) <- line,
         [_, total, _used, available] <-
           Regex.run(~r/\s(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s+\S.*$/, line),
         {total, ""} when total > 0 <- Integer.parse(total),
         {available, ""} <- Integer.parse(available) do
      {:ok, %{total_bytes: total * 1024, available_bytes: available * 1024}}
    else
      _ -> {:error, "unreadable df output: #{String.slice(output, 0, 200)}"}
    end
  end

  ## ---------- the process ----------

  @impl true
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:openresults, :disk_space_interval, :timer.minutes(1))
      end)

    state = measure(%{interval: interval, last: nil})
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:measure, state) do
    state = measure(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, :ok, measure(state)}

  defp schedule(%{interval: :disabled}), do: :ok
  defp schedule(%{interval: ms}), do: Process.send_after(self(), :measure, ms)

  defp measure(state) do
    dir = path()
    result = read(dir)
    :ets.insert(@table, {:measurement, %{result: result, at: DateTime.utc_now(), path: dir}})
    reading = reading()
    log_transition(state.last, reading)
    %{state | last: reading.status}
  end

  defp read(dir) do
    task =
      Task.async(fn ->
        try do
          call_reader(Application.get_env(:openresults, :disk_space_reader), dir)
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{total_bytes: t, available_bytes: a}} = ok}
      when is_integer(t) and t > 0 and is_integer(a) and a >= 0 ->
        ok

      {:ok, {:error, reason}} ->
        {:error, if(is_binary(reason), do: reason, else: inspect(reason))}

      {:ok, other} ->
        {:error, "the reader answered #{inspect(other)}"}

      nil ->
        {:error, "df did not answer within #{div(@timeout, 1000)} seconds"}
    end
  end

  defp call_reader(nil, dir), do: df(dir)
  defp call_reader({m, f}, dir), do: apply(m, f, [dir])
  defp call_reader(fun, dir) when is_function(fun, 1), do: fun.(dir)

  defp log_transition(same, %{status: same}), do: :ok

  # The test environment's reader, which is not a failure to report.
  defp log_transition(_before, %{status: :unknown, error: @unmeasured}), do: :ok

  defp log_transition(_before, %{status: :unknown} = r),
    do:
      Logger.warning(
        "Free disk space on #{r.path} could not be measured (#{r.error}); " <>
          "installation keys are not refused for storage while it cannot be"
      )

  defp log_transition(_before, %{status: :low} = r),
    do:
      Logger.warning(
        "Free disk space on #{r.path} is #{Float.round(r.free_percent, 1)}%, below the " <>
          "#{r.floor_percent}% floor: installation keys are refused storage_low"
      )

  defp log_transition(before, %{status: :ok} = r) when before in [:low, :unknown],
    do: Logger.info("Free disk space on #{r.path} is #{Float.round(r.free_percent, 1)}% again")

  defp log_transition(_before, _reading), do: :ok
end
