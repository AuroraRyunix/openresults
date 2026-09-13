defmodule OpenResults.Stats.Collector do
  @moduledoc """
  Owns the counters' ETS table, turns finished minutes into history, and
  samples the host, the BEAM and the database on timers.

  Supervised and started before the endpoint, for the reason
  `OpenResults.Snapshots.LatestIdCache` gives: a table created by whichever
  request came first would die with that request's connection.

  ## Every tick (5 seconds)

  1. Creates the counter rows for the current and the next minute, so a
     request's increment finds its row already there (`OpenResults.Stats`).
  2. Takes every row of a minute that has ended out of the table - `take`,
     so an increment racing it recreates the row for the next tick rather
     than being lost - and adds it to two histories: per minute for the last
     hour, and per quarter hour for the last 24 hours. The quarter-hour
     buckets are filled as the minutes arrive, so the day never needs the
     minutes that made it.
  3. Samples `/proc` and the BEAM (`OpenResults.Stats.SystemInfo`), keeps
     the CPU and load averages of each minute beside its traffic, and starts
     a count of the open HTTP connections in a process of its own.

  Every minute it also counts the database's rows in a separate process
  (`OpenResults.Stats.DbCounts`), so a slow count never holds up a tick or
  the page.

  ## Bounds

  60 minutes and 96 quarter hours, each a few fixed-size lists, plus event
  counts (a dozen names) and tournament slugs. A minute keeps its
  200 busiest slugs and a quarter hour its 500; the rest of either is
  added to that bucket's "other". With the hot table's own cap of 2,000
  slugs a minute, the worst case is 60 × 200 + 97 × 500 = 60,500 slug
  entries, a few megabytes, and only if that many different published
  tournaments are read within one day.

  ## Time

  Nothing here reads the clock except `tick/1` and `report/1` through the
  `:clock` option (Unix seconds), so tests drive time by calling `tick/2`
  and `report/2` with the time they want.
  """

  use GenServer

  alias OpenResults.Stats
  alias OpenResults.Stats.DbCounts
  alias OpenResults.Stats.Histogram
  alias OpenResults.Stats.SystemInfo

  @minute_slugs 200
  @quarter_slugs 500
  @hour_minutes 60
  @day_quarters 96

  @req_len 5 + Histogram.size() + 3
  @repo_len 1 + 2 * Histogram.size() + 1
  @groups Stats.groups()

  ## ---------- the process ----------

  @doc """
  Options: `:name` (default `#{inspect(__MODULE__)}`, `nil` for none),
  `:table` (default `OpenResults.Stats.table/0`), `:clock` (a zero-arity
  function answering Unix seconds), `:tick` (milliseconds or `:manual`),
  `:db_interval` (milliseconds or `:manual`), `:proc_root` (default
  `"/proc"`), `:connections` (a zero-arity function answering
  `{:ok, n}` or `:error`).
  """
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Runs one tick now, as if the clock read `now` (Unix seconds)."
  def tick(server, now \\ nil), do: GenServer.call(server, {:tick, now})

  @doc "What the page shows, as of `now` (Unix seconds, default the clock)."
  def report(server, now \\ nil), do: GenServer.call(server, {:report, now}, 10_000)

  @doc "Counts the database's rows in the calling process and keeps the result."
  def refresh_db_counts(server \\ __MODULE__) do
    GenServer.call(server, {:db_counts, read_db_counts(), DateTime.utc_now()})
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, Stats.table())
    :ets.new(table, [:set, :public, :named_table, write_concurrency: true])

    clock = Keyword.get(opts, :clock, fn -> System.os_time(:second) end)
    now = clock.()

    state = %{
      table: table,
      clock: clock,
      started_at: now,
      minutes: %{},
      quarters: %{},
      cpu_prev: nil,
      system: nil,
      db: nil,
      db_at: nil,
      proc_root: Keyword.get(opts, :proc_root, "/proc"),
      connections: Keyword.get(opts, :connections, fn -> :error end),
      connection_count: :error,
      tick: Keyword.get(opts, :tick, 5_000),
      db_interval: Keyword.get(opts, :db_interval, 60_000)
    }

    precreate(table, div(now, 60))
    # A first sample now, so the page has server figures from the first
    # request rather than after the first tick.
    state = sample(state, div(now, 60))
    schedule(:tick, state.tick)
    schedule(:db_counts, state.db_interval, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(:tick, state.tick)
    {:noreply, run_tick(state, state.clock.())}
  end

  def handle_info(:db_counts, state) do
    parent = self()

    # Its own process: a count that takes seconds holds up nothing, and one
    # that raises takes nothing down.
    spawn(fn -> send(parent, {:db_counts, read_db_counts(), DateTime.utc_now()}) end)
    schedule(:db_counts, state.db_interval)
    {:noreply, state}
  end

  def handle_info({:db_counts, counts, at}, state), do: {:noreply, keep_db(state, counts, at)}

  def handle_info({:connections, count}, state) do
    system = state.system && %{state.system | connections: count}
    {:noreply, %{state | connection_count: count, system: system}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:tick, now}, _from, state),
    do: {:reply, :ok, run_tick(state, now || state.clock.())}

  def handle_call({:report, now}, _from, state),
    do: {:reply, build_report(state, now || state.clock.()), state}

  def handle_call({:db_counts, counts, at}, _from, state),
    do: {:reply, :ok, keep_db(state, counts, at)}

  defp keep_db(state, {:ok, counts}, at), do: %{state | db: counts, db_at: at}
  # A failed count keeps the last good one on the page.
  defp keep_db(state, {:error, _reason}, _at), do: state

  defp read_db_counts do
    {:ok, DbCounts.read()}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp schedule(message, interval, first \\ nil)
  defp schedule(_message, :manual, _first), do: :ok
  defp schedule(message, ms, first), do: Process.send_after(self(), message, first || ms)

  ## ---------- a tick ----------

  @doc false
  def run_tick(state, now) do
    minute = div(now, 60)
    precreate(state.table, minute)
    precreate(state.table, minute + 1)

    state
    |> fold_finished(minute)
    |> prune(minute)
    |> sample(minute)
  end

  defp precreate(table, minute) do
    for row <- Stats.blank_rows(minute), do: :ets.insert_new(table, row)
    :ok
  end

  defp fold_finished(state, minute) do
    rows =
      for key <- keys_before(state.table, minute),
          row <- :ets.take(state.table, key),
          do: row

    Enum.reduce(fold_rows(rows), state, fn {m, agg}, state ->
      %{
        state
        | minutes: add_bucket(state.minutes, m, agg, @minute_slugs),
          quarters: add_bucket(state.quarters, quarter(m), agg, @quarter_slugs)
      }
    end)
  end

  # Each history trims its buckets to its own slug cap.
  defp add_bucket(buckets, at, agg, keep) do
    Map.update(buckets, at, trim_slugs(agg, keep), &(agg |> merge(&1) |> trim_slugs(keep)))
  end

  # Keys of every row whose minute is before `minute`. One match spec per
  # row size, because a match head fixes the tuple's arity. Rows of the same
  # minute and tag from different schedulers are added together by
  # `fold_rows/1`.
  defp keys_before(table, minute), do: select(table, {:<, :"$1", minute}, {:element, 1, :"$_"})

  defp rows_from(table, minute), do: select(table, {:>=, :"$1", minute}, :"$_")

  defp select(table, guard, result) do
    specs =
      for size <- [2, 1 + @req_len, 1 + @repo_len] do
        head = List.to_tuple([{:"$1", :_, :_} | List.duplicate(:_, size - 1)])
        {head, [guard], [result]}
      end

    :ets.select(table, specs)
  end

  defp prune(state, minute) do
    oldest_minute = minute - @hour_minutes
    oldest_quarter = quarter(minute) - (@day_quarters - 1) * 15

    %{
      state
      | minutes: Map.reject(state.minutes, fn {m, _} -> m < oldest_minute end),
        quarters: Map.reject(state.quarters, fn {q, _} -> q < oldest_quarter end)
    }
  end

  defp sample(state, minute) do
    times =
      case SystemInfo.cpu_times(state.proc_root) do
        {:ok, times} -> times
        :error -> nil
      end

    cpu = if state.cpu_prev && times, do: SystemInfo.cpu_percent(state.cpu_prev, times)

    load =
      case SystemInfo.loadavg(state.proc_root) do
        {:ok, load} -> load
        :error -> nil
      end

    memory =
      case SystemInfo.meminfo(state.proc_root) do
        {:ok, memory} -> memory
        :error -> nil
      end

    count_connections(state.connections)

    system = %{
      cpu_percent: cpu,
      load: load,
      memory: memory,
      beam: SystemInfo.beam(),
      connections: state.connection_count,
      sampled_at: DateTime.utc_now()
    }

    gauges = %{cpu: cpu, load: load && elem(load, 0)}

    %{
      state
      | cpu_prev: times,
        system: system,
        minutes: add_gauges(state.minutes, minute, gauges),
        quarters: add_gauges(state.quarters, quarter(minute), gauges)
    }
  end

  # Counting connections asks every acceptor's supervisor in turn, and under
  # load each of those calls waits its turn behind the connections
  # themselves: 1.7 s at 50 busy clients on one core, measured. So it runs in
  # its own process and the answer arrives as a message, and neither a tick
  # nor the page waits for it. The page shows the last count.
  defp count_connections(fun) do
    parent = self()

    spawn(fn ->
      count =
        try do
          fun.()
        rescue
          _ -> :error
        catch
          :exit, _ -> :error
        end

      send(parent, {:connections, count})
    end)
  end

  defp add_gauges(buckets, at, gauges) do
    Map.update(buckets, at, add_gauge(empty(), gauges), &add_gauge(&1, gauges))
  end

  defp add_gauge(agg, gauges) do
    Enum.reduce(gauges, agg, fn
      {_name, nil}, agg ->
        agg

      {name, value}, agg ->
        Map.update!(agg, name, fn {sum, n} -> {sum + value, n + 1} end)
    end)
  end

  ## ---------- folding rows ----------

  @doc "An empty bucket."
  def empty do
    %{
      req: %{},
      repo: List.duplicate(0, @repo_len),
      events: %{},
      slugs: %{},
      slug_other: 0,
      cpu: {0, 0},
      load: {0, 0}
    }
  end

  @doc false
  # Rows as taken from the table, into `%{minute => bucket}`.
  def fold_rows(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      {minute, tag, _scheduler} = elem(row, 0)
      [_key | values] = Tuple.to_list(row)
      Map.update(acc, minute, add_row(empty(), tag, values), &add_row(&1, tag, values))
    end)
  end

  defp add_row(agg, group, values) when group in @groups,
    do: %{agg | req: Map.update(agg.req, group, values, &add_lists(&1, values))}

  defp add_row(agg, :repo, values), do: %{agg | repo: add_lists(agg.repo, values)}

  defp add_row(agg, {:event, event}, [n]),
    do: %{agg | events: Map.update(agg.events, event, n, &(&1 + n))}

  defp add_row(agg, {:slug, slug}, [n]),
    do: %{agg | slugs: Map.update(agg.slugs, slug, n, &(&1 + n))}

  defp add_row(agg, :slug_other, [n]), do: %{agg | slug_other: agg.slug_other + n}
  defp add_row(agg, _distinct_or_unknown, _values), do: agg

  @doc "Adds two buckets together."
  def merge(a, b) do
    %{
      req: Map.merge(a.req, b.req, fn _group, x, y -> add_lists(x, y) end),
      repo: add_lists(a.repo, b.repo),
      events: Map.merge(a.events, b.events, fn _event, x, y -> x + y end),
      slugs: Map.merge(a.slugs, b.slugs, fn _slug, x, y -> x + y end),
      slug_other: a.slug_other + b.slug_other,
      cpu: add_pair(a.cpu, b.cpu),
      load: add_pair(a.load, b.load)
    }
  end

  defp add_lists(a, b), do: Enum.zip_with(a, b, &(&1 + &2))
  defp add_pair({s1, n1}, {s2, n2}), do: {s1 + s2, n1 + n2}

  @doc false
  # Keeps a bucket's `keep` busiest slugs and adds the rest to "other".
  def trim_slugs(%{slugs: slugs} = agg, keep) when map_size(slugs) <= keep, do: agg

  def trim_slugs(agg, keep) do
    {kept, dropped} = agg.slugs |> Enum.sort_by(fn {_slug, n} -> -n end) |> Enum.split(keep)

    %{
      agg
      | slugs: Map.new(kept),
        slug_other: agg.slug_other + Enum.sum(Enum.map(dropped, &elem(&1, 1)))
    }
  end

  @doc "The first minute of the quarter hour `minute` is in."
  def quarter(minute), do: minute - rem(minute, 15)

  ## ---------- the report ----------

  defp build_report(state, now) do
    minute = div(now, 60)

    # The minute in progress, read without taking it, so the page includes
    # it without disturbing the counters.
    live = fold_rows(rows_from(state.table, minute))

    {minutes, quarters} =
      Enum.reduce(live, {state.minutes, state.quarters}, fn {m, agg}, {minutes, quarters} ->
        {Map.update(minutes, m, agg, &merge(agg, &1)),
         Map.update(quarters, quarter(m), agg, &merge(agg, &1))}
      end)

    # The 60 finished minutes, then the one in progress.
    hour = for m <- (minute - @hour_minutes)..minute, do: {m, Map.get(minutes, m, empty())}

    day =
      for i <- (@day_quarters - 1)..0//-1 do
        q = quarter(minute) - i * 15
        {q, Map.get(quarters, q, empty())}
      end

    %{
      now: DateTime.from_unix!(now),
      since: DateTime.from_unix!(state.started_at),
      hour: hour,
      day: day,
      system: state.system,
      db: state.db,
      db_at: state.db_at
    }
  end
end
