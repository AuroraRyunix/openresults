defmodule OpenResults.TournamentGroups.Epochs do
  @moduledoc """
  A counter per slug, in ETS: how many times something BESIDE a tournament
  changed what its pages show. See `OpenResults.TournamentGroups`, "Telling
  the pages".

  `OpenResultsWeb.Plugs.Revalidate` reads it on every request to a tournament
  page, which is why it is ETS and not a column: that path answers from
  memory (`OpenResults.Snapshots.LatestIdCache`,
  `OpenResults.Tournaments.StatusCache`) and this must not be the query that
  puts the database back on it. Only slugs that were ever bumped have an
  entry, so a scanner walking random slugs grows nothing.
  """

  use GenServer

  @table __MODULE__

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The epoch of `slug`; 0 when it was never bumped."
  @spec get(String.t()) :: non_neg_integer()
  def get(slug) do
    case :ets.lookup(@table, slug) do
      [{^slug, epoch}] -> epoch
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Moves `slug` to its next epoch."
  @spec bump(String.t()) :: :ok
  def bump(slug) do
    :ets.update_counter(@table, slug, {2, 1}, {slug, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets everything. For tests."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, opts}
  end
end
