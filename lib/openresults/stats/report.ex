defmodule OpenResults.Stats.Report do
  @moduledoc """
  Reads figures out of the buckets `OpenResults.Stats.Collector.report/2`
  returns. Pure functions of a bucket (or a list of `{time, bucket}` points),
  so the page's arithmetic is tested without a page.
  """

  alias OpenResults.Stats
  alias OpenResults.Stats.Collector
  alias OpenResults.Stats.Histogram

  @classes ["2xx", "304", "3xx", "4xx", "5xx"]

  @doc "The status classes, in the order a request row counts them."
  def classes, do: @classes

  @doc "Every point's bucket added into one."
  def total(points),
    do: Enum.reduce(points, Collector.empty(), fn {_t, b}, acc -> Collector.merge(acc, b) end)

  @doc "`fun` applied to each point's bucket."
  def series(points, fun), do: Enum.map(points, fn {_t, bucket} -> fun.(bucket) end)

  @doc "Quarter-hour points grouped into hours: 96 points become 24."
  def hourly(points) do
    points
    |> Enum.chunk_every(4)
    |> Enum.map(fn [{t, _} | _] = chunk -> {t, total(chunk)} end)
  end

  @doc "Requests in a bucket, for one route group or `:all`."
  def requests(bucket, :all), do: Enum.sum(Enum.map(Stats.groups(), &requests(bucket, &1)))

  def requests(bucket, group) do
    case bucket.req do
      %{^group => row} -> row |> Enum.take(5) |> Enum.sum()
      _ -> 0
    end
  end

  @doc "`[{class, count}]` across every route group."
  def status_classes(bucket) do
    counts =
      bucket.req
      |> Map.values()
      |> Enum.map(&Enum.take(&1, 5))
      |> Enum.reduce([0, 0, 0, 0, 0], &Enum.zip_with(&1, &2, fn a, b -> a + b end))

    Enum.zip(@classes, counts)
  end

  @doc "Response-time percentiles for one route group or `:all`: `%{p50:, p95:, p99:, count:}`."
  def latency(bucket, group) do
    buckets =
      case group do
        :all ->
          bucket.req
          |> Map.values()
          |> Enum.map(&durations/1)
          |> Enum.reduce(Histogram.empty(), &Histogram.add/2)

        group ->
          case bucket.req do
            %{^group => row} -> durations(row)
            _ -> Histogram.empty()
          end
      end

    percentiles(buckets)
  end

  defp durations(row), do: Enum.slice(row, 5, Histogram.size())

  defp percentiles(buckets) do
    %{
      count: Enum.sum(buckets),
      p50: Histogram.percentile(buckets, 50),
      p95: Histogram.percentile(buckets, 95),
      p99: Histogram.percentile(buckets, 99)
    }
  end

  @doc """
  The rendered-page cache: hits, misses, 304s, the hit rate (hits among
  hits and misses) and the revalidation share (304s among all three), both
  as percentages or `nil` with nothing to divide.
  """
  def cache(bucket) do
    [hits, misses, not_modified] =
      bucket.req
      |> Map.values()
      |> Enum.map(&Enum.take(&1, -3))
      |> Enum.reduce([0, 0, 0], &Enum.zip_with(&1, &2, fn a, b -> a + b end))

    %{
      hits: hits,
      misses: misses,
      not_modified: not_modified,
      hit_rate: percent(hits, hits + misses),
      revalidation_share: percent(not_modified, hits + misses + not_modified)
    }
  end

  @doc "Repo queries: how many, and query-time and pool-queue-time percentiles."
  def repo(bucket) do
    size = Histogram.size()
    [queries | rest] = bucket.repo
    {query, rest} = Enum.split(rest, size)
    {queue, [queued]} = Enum.split(rest, size)

    %{
      queries: queries,
      queued: queued,
      query: percentiles(query),
      queue: percentiles(queue)
    }
  end

  @doc "How often `event` was counted in a bucket."
  def event(bucket, event), do: Map.get(bucket.events, event, 0)

  @doc "`[{code, count}]` refusals in a bucket, most frequent first."
  def refusals(bucket) do
    for({{:refused, code}, n} <- bucket.events, n > 0, do: {code, n})
    |> Enum.sort_by(fn {code, n} -> {-n, code} end)
  end

  @doc """
  The `n` busiest tournaments in a bucket, `{[{slug, count}], rest}`, where
  `rest` is every other counted request - the slugs past the top `n` and the
  ones folded into "other" by a cap.
  """
  def top_slugs(bucket, n) do
    {top, others} =
      bucket.slugs
      |> Enum.sort_by(fn {slug, count} -> {-count, slug} end)
      |> Enum.split(n)

    {top, bucket.slug_other + Enum.sum(Enum.map(others, &elem(&1, 1)))}
  end

  @doc "The average of a sampled gauge (`:cpu` or `:load`) in a bucket, or `nil`."
  def gauge(bucket, name) do
    case Map.fetch!(bucket, name) do
      {_sum, 0} -> nil
      {sum, n} -> sum / n
    end
  end

  @doc "`part` as a percentage of `whole`, or `nil` when `whole` is 0."
  def percent(_part, 0), do: nil
  def percent(part, whole), do: part * 100 / whole
end
