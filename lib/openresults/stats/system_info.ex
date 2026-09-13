defmodule OpenResults.Stats.SystemInfo do
  @moduledoc """
  What the host and the BEAM say about load and memory, for the stats page.

  The host figures come from Linux's `/proc` - `loadavg`, `stat` and
  `meminfo` - read as plain files, with no `:os_mon` and no shelling out
  (the same reasoning as `OpenResults.DiskSpace`: nothing extra running on a
  small shared box). Everywhere else, or when a file does not parse, the
  reading is `:error` and the page says "not measured".

  Every reader takes the directory to read from, so the parsers are tested
  against fixture files rather than whatever machine the tests run on.
  """

  @doc "`{:ok, {one, five, fifteen}}` load averages, or `:error`."
  @spec loadavg(Path.t()) :: {:ok, {float(), float(), float()}} | :error
  def loadavg(root) do
    with {:ok, text} <- read(root, "loadavg"),
         [one, five, fifteen | _] <- String.split(text),
         {:ok, one} <- float(one),
         {:ok, five} <- float(five),
         {:ok, fifteen} <- float(fifteen) do
      {:ok, {one, five, fifteen}}
    else
      _ -> :error
    end
  end

  @doc """
  `{:ok, {busy, total}}` jiffies from the aggregate `cpu` line of
  `/proc/stat`, or `:error`. Busy is everything but idle and iowait; guest
  time is already inside user and nice, so it is not counted twice.
  """
  @spec cpu_times(Path.t()) :: {:ok, {non_neg_integer(), non_neg_integer()}} | :error
  def cpu_times(root) do
    with {:ok, text} <- read(root, "stat"),
         "cpu " <> rest <- text |> String.split("\n", parts: 2) |> hd(),
         fields when length(fields) >= 4 <- String.split(rest),
         {:ok, numbers} <- integers(Enum.take(fields, 8)) do
      [user, nice, system, idle | more] = numbers ++ List.duplicate(0, 8 - length(numbers))
      [iowait, irq, softirq, steal] = more
      busy = user + nice + system + irq + softirq + steal
      {:ok, {busy, busy + idle + iowait}}
    else
      _ -> :error
    end
  end

  @doc "Busy share of the time between two `cpu_times/1` readings, 0.0-100.0, or `nil`."
  @spec cpu_percent({integer(), integer()} | nil, {integer(), integer()} | nil) :: float() | nil
  def cpu_percent({busy0, total0}, {busy1, total1}) when total1 > total0 do
    Float.round(max(0, busy1 - busy0) * 100 / (total1 - total0), 1)
  end

  def cpu_percent(_before, _after), do: nil

  @doc "`{:ok, %{total_bytes: n, available_bytes: n}}` from `/proc/meminfo`, or `:error`."
  @spec meminfo(Path.t()) :: {:ok, map()} | :error
  def meminfo(root) do
    with {:ok, text} <- read(root, "meminfo") do
      fields =
        for line <- String.split(text, "\n"),
            [name, value] <- [String.split(line, ":", parts: 2)],
            [number | _unit] <- [String.split(value)],
            {kb, ""} <- [Integer.parse(number)],
            into: %{},
            do: {name, kb * 1024}

      case fields do
        %{"MemTotal" => total, "MemAvailable" => available} when total > 0 ->
          {:ok, %{total_bytes: total, available_bytes: available}}

        _ ->
          :error
      end
    end
  end

  @doc "The BEAM's own figures. Cheap enough to take every few seconds."
  @spec beam() :: map()
  def beam do
    memory = :erlang.memory([:total, :processes, :ets, :binary])
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    %{
      memory: Map.new(memory),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: System.schedulers_online(),
      logical_processors: known(:erlang.system_info(:logical_processors)),
      logical_processors_available: known(:erlang.system_info(:logical_processors_available)),
      run_queue: :erlang.statistics(:total_run_queue_lengths_all),
      run_queues: :erlang.statistics(:run_queue_lengths_all),
      process_count: :erlang.system_info(:process_count),
      uptime_ms: uptime_ms
    }
  end

  defp known(n) when is_integer(n), do: n
  defp known(_unknown), do: nil

  defp read(root, name) do
    case File.read(Path.join(root, name)) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> :error
    end
  end

  defp float(text) do
    case Float.parse(text) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp integers(texts) do
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
      case Integer.parse(text) do
        {n, ""} -> {:cont, {:ok, acc ++ [n]}}
        _ -> {:halt, :error}
      end
    end)
  end
end
