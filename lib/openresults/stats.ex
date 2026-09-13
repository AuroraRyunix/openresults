defmodule OpenResults.Stats do
  @moduledoc """
  Traffic, cache, publishing and database counters for the admin panel's
  stats page (`/admin/stats`), kept in memory and never on disk.

  ## The cost this must not add

  The 2026-09-12 load test (`docs/load-test-2026-09-12.md`) got a single
  pinned core to 5,700-6,500 requests a second, and every one of them now
  passes through here. So recording a request is held to what one
  `:ets.update_counter/3` costs, and no more:

    * no GenServer call and no message: the counter is incremented in the
      process that served the request, straight into a public ETS table;
    * no formatting, no `DateTime`, no database: the minute a request belongs
      to is `System.os_time(:second)` divided by 60, read once per request;
    * ONE increment per request, carrying its status class, its duration
      bucket and the page cache's decision together - `update_counter/3`
      takes a list of positions, and all of them live in the same row. The
      position lists are built at compile time, so the increment allocates
      nothing but its key;
    * the page cache's decision reaches that increment on the conn
      (`OpenResultsWeb.Plugs.Revalidate` puts it in `conn.private`), rather
      than costing a second increment of its own;
    * rows for the current and the next minute are created ahead of time by
      `OpenResults.Stats.Collector`, so the common increment never builds a
      default row. When one is missing (the first seconds after a boot, or a
      clock that jumped), the increment falls back to creating it;
    * a missing TABLE (the collector restarting) is swallowed. A counter must
      never be the reason a page fails, and a telemetry handler that raised
      would be detached for the rest of the node's life.

  A tournament page costs one more increment, for its slug.

  Every key ends in the scheduler that made the increment
  (`:erlang.system_info(:scheduler_id)`), so on a box running two schedulers
  the two never take the same row lock for the same minute; the collector
  adds the rows together.

  `docs/stats-overhead-2026-09-13.md` has the throughput before and after.

  ## What a row is

  | key | row after the key |
  |---|---|
  | `{minute, group, scheduler}` | 5 status classes (2xx, 304, other 3xx, 4xx, 5xx), `Histogram.size/0` duration buckets, then page cache hits, misses and 304 revalidations |
  | `{minute, :repo, scheduler}` | queries, query-time buckets, queue-time buckets, queries that reported a queue time |
  | `{minute, {:event, name}, 0}` | a count: publishes, mints, registrations, refusals by code |
  | `{minute, {:slug, slug}, scheduler}` | a tournament's page requests |
  | `{minute, :slug_distinct, 0}` / `{minute, :slug_other, 0}` | slug rows created this minute; requests folded away past the cap |

  The collector takes every finished minute's rows out of the table and
  folds them into its own per-minute and per-quarter-hour buckets, so the
  table itself holds one or two minutes at any time.

  ## Private by construction

  Nothing here is given an address, a user agent, a query string or a path
  beyond a tournament's slug, so none can be stored. The route group is
  decided from the path's first segment and thrown away.

  ## Bounded

  At most `slug_cap/0` slug rows are created per minute; requests for
  any more land in one "other" row. Only a tournament that has published is
  counted at all (`OpenResultsWeb.StatsTelemetry`), so a scan of made-up
  slugs cannot add a row. The collector's own bounds are in its moduledoc.
  """

  alias OpenResults.Stats.Collector
  alias OpenResults.Stats.Histogram

  @table :openresults_stats

  @groups [:public, :static, :api_read, :api_write, :admin]

  @buckets Histogram.size()
  # Status classes at 2..6, duration buckets from 7, cache decisions after.
  @bucket_base 7
  @cache_base @bucket_base + @buckets
  @req_size @cache_base + 2
  @repo_size 1 + 1 + 2 * @buckets + 1

  # Every position list a request increment can need, by status class,
  # duration bucket and cache decision - literals, so building one costs
  # nothing on the request path.
  @request_ops (for class <- 0..4 do
                  for bucket <- 0..(@buckets - 1) do
                    for cache <- 0..3 do
                      base = [{2 + class, 1}, {@bucket_base + bucket, 1}]
                      if cache == 0, do: base, else: base ++ [{@cache_base + cache - 1, 1}]
                    end
                    |> List.to_tuple()
                  end
                  |> List.to_tuple()
                end)
               |> List.to_tuple()

  @slug_cap 2_000

  @doc "The route groups, in display order."
  def groups, do: @groups

  @doc "The ETS table the counters live in."
  def table, do: @table

  @doc "Most tournament slug rows created in one minute."
  def slug_cap, do: @slug_cap

  @doc "The minute a request arriving now is counted in: whole minutes since the Unix epoch."
  @spec minute_now() :: integer()
  def minute_now, do: div(System.os_time(:second), 60)

  ## ---------- recording: the request path ----------

  @doc """
  Counts one response in `table` for `minute`: its route `group`, its HTTP
  `status` (`nil` when the request ended before one was chosen, counted as
  5xx), its duration in microseconds, and the page cache's decision on it
  (`nil` when the page cache was not asked).
  """
  def record_request(table, minute, group, status, us, cache \\ nil) do
    ops =
      @request_ops
      |> elem(class_index(status))
      |> elem(Histogram.index(us))
      |> elem(cache_index(cache))

    increment(table, {minute, group, scheduler()}, ops, @req_size)
  end

  @doc """
  Counts one Repo query that took `query_us` microseconds to run, having
  waited `queue_us` for a connection (`nil` when the adapter did not say).
  """
  def record_query(query_us, queue_us), do: record_query(@table, minute_now(), query_us, queue_us)

  @doc false
  def record_query(table, minute, query_us, queue_us) do
    ops = [{2, 1}, {3 + Histogram.index(query_us), 1}]

    ops =
      if is_integer(queue_us),
        do: [{3 + @buckets + Histogram.index(queue_us), 1}, {@repo_size, 1} | ops],
        else: ops

    increment(table, {minute, :repo, scheduler()}, ops, @repo_size)
  end

  @doc """
  Counts one event: `{:publish, :operator}`, `{:publish, :installation}`,
  `:mint`, `:registration`, or `{:refused, code}`.
  """
  def count(event), do: count(@table, minute_now(), event)

  @doc false
  def count(table, minute, event),
    do: increment(table, {minute, {:event, event}, 0}, [{2, 1}], 2)

  @doc """
  Counts one page request for a published tournament. Callers decide that it
  is one; see `OpenResultsWeb.StatsTelemetry`.
  """
  def record_view(table, minute, slug) when is_binary(slug) do
    key = {minute, {:slug, slug}, scheduler()}

    case :ets.update_counter(table, key, {2, 1}, {key, 0}) do
      1 -> admit_slug(table, minute, key)
      _seen -> :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # The first request for a slug this minute: over the cap, its row is taken
  # back out and its count moved to "other". A row taken while another
  # process increments it is recreated and comes through here again, so the
  # distinct counter may overcount - which only tightens the bound.
  defp admit_slug(table, minute, key) do
    distinct = {minute, :slug_distinct, 0}

    if :ets.update_counter(table, distinct, {2, 1}, {distinct, 0}) > @slug_cap do
      moved =
        case :ets.take(table, key) do
          [{_key, n}] -> n
          [] -> 0
        end

      other = {minute, :slug_other, 0}
      :ets.update_counter(table, other, {2, moved}, {other, 0})
    end
  end

  defp scheduler, do: :erlang.system_info(:scheduler_id)

  # 1xx and 2xx together: nothing here upgrades a connection.
  defp class_index(status) when is_integer(status) and status < 300, do: 0
  defp class_index(304), do: 1
  defp class_index(status) when is_integer(status) and status < 400, do: 2
  defp class_index(status) when is_integer(status) and status < 500, do: 3
  defp class_index(_5xx_or_none), do: 4

  defp cache_index(nil), do: 0
  defp cache_index(:hit), do: 1
  defp cache_index(:miss), do: 2
  defp cache_index(:not_modified), do: 3

  # The pre-created row first; the default-row form only when it is missing.
  defp increment(table, key, ops, size) do
    :ets.update_counter(table, key, ops)
    :ok
  rescue
    ArgumentError ->
      try do
        :ets.update_counter(table, key, ops, blank_row(key, size))
        :ok
      rescue
        ArgumentError -> :ok
      end
  end

  @doc false
  def blank_row(key, size), do: :erlang.setelement(1, :erlang.make_tuple(size, 0), key)

  @doc false
  # The rows `OpenResults.Stats.Collector` creates ahead of each minute.
  def blank_rows(minute) do
    for scheduler <- 1..:erlang.system_info(:schedulers),
        {tag, size} <- [{:repo, @repo_size} | Enum.map(@groups, &{&1, @req_size})],
        do: blank_row({minute, tag, scheduler}, size)
  end

  ## ---------- reading: the admin page ----------

  @doc """
  Everything the stats page shows, from the running collector - see
  `OpenResults.Stats.Collector.report/1`. `nil` when it is not running.
  """
  def report do
    Collector.report(Collector)
  catch
    :exit, _not_running -> nil
  end
end
