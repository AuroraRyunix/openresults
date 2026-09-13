defmodule OpenResults.Stats.Histogram do
  @moduledoc """
  Fixed histogram buckets for durations, in microseconds, and the
  percentiles read back out of them.

  Fixed rather than adaptive so recording one duration is a comparison
  chain and one counter increment, with nothing to allocate and nothing to
  sort - see `OpenResults.Stats` for why the request path cannot afford
  more. A percentile is therefore only as sharp as its bucket: the page
  reports "at most 2 ms", the upper edge of the bucket the rank falls in,
  never an interpolated figure that looks more precise than it is.

  The edges are a 1-2-5 series from 0.1 ms to 5 s, which puts the page
  cache's hit path (0.3-0.7 ms in the 2026-09-12 load test) and a cold render
  (20-30 ms) in different buckets, and everything slower than 5 s in one
  overflow bucket.
  """

  @bounds [
    100,
    200,
    500,
    1_000,
    2_000,
    5_000,
    10_000,
    20_000,
    50_000,
    100_000,
    200_000,
    500_000,
    1_000_000,
    2_000_000,
    5_000_000
  ]

  @size length(@bounds) + 1

  @doc "Upper edges of every bucket but the last, in microseconds."
  def bounds, do: @bounds

  @doc "How many buckets there are, the overflow bucket included."
  def size, do: @size

  @doc "The zero-based bucket a duration in microseconds falls in."
  @spec index(integer()) :: non_neg_integer()
  for {bound, i} <- Enum.with_index(@bounds) do
    def index(us) when us <= unquote(bound), do: unquote(i)
  end

  def index(_us), do: @size - 1

  @doc """
  The upper edge, in microseconds, of the bucket holding the `p`th
  percentile (`p` in 0..100) of `counts` - a list of `size/0` bucket
  counts - or `:overflow` when that is the last bucket, or `nil` when there
  are no samples at all.
  """
  @spec percentile([non_neg_integer()], number()) :: pos_integer() | :overflow | nil
  def percentile(counts, p) when is_list(counts) do
    total = Enum.sum(counts)

    if total == 0 do
      nil
    else
      # The sample at rank ceil(p% of n), counting from 1: the p50 of four
      # samples is the second, the p99 of ten is the tenth.
      rank = max(1, ceil(total * p / 100))
      counts |> find_bucket(rank, 0, 0) |> edge()
    end
  end

  defp find_bucket([count | rest], rank, seen, i) do
    if seen + count >= rank, do: i, else: find_bucket(rest, rank, seen + count, i + 1)
  end

  defp find_bucket([], _rank, _seen, i), do: i - 1

  defp edge(i) when i >= @size - 1, do: :overflow
  defp edge(i), do: Enum.at(@bounds, i)

  @doc "Adds two lists of bucket counts, element by element."
  def add(a, b), do: Enum.zip_with(a, b, &(&1 + &2))

  @doc "An empty list of bucket counts."
  def empty, do: List.duplicate(0, @size)
end
