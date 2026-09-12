defmodule OpenResults.Tournaments.StatusCache do
  @moduledoc """
  Each tournament's visibility, kept out of the database on the read path.

  `OpenResultsWeb.Plugs.Revalidate` answers most requests on this site from
  ETS alone - that was the whole of the 2026-09-12 load test's fix, see
  `OpenResults.Snapshots.LatestIdCache`. Visibility is now a question every
  one of those requests has to ask before it may answer, so asking it of the
  database would put a query back on exactly the path that fix took it off.

  ## Writes win over reads

  The rule that keeps this honest, and the difference from `LatestIdCache`'s
  plain overwrite: a status changes by moderation, and a stale `listed` for a
  tournament just hidden is not "a 200 instead of a 304" - it is the hidden
  page staying public.

  So there are two ways in:

    * `put/2` - a writer, after its write has committed. Overwrites.
    * `remember/2` - a reader, after a cache miss queried the database.
      Inserts ONLY if nothing is there.

  The race this closes: a reader misses, queries, and gets the OLD status; a
  moderator's change commits and `put/2`s the new one; the reader then stores
  what it read. With an overwrite that would put the old status back for good.
  With `:ets.insert_new/2` the reader's late write finds the writer's entry
  and does nothing.

  What is left is two writers racing each other on the same slug, which is two
  moderators clicking on one tournament in the same millisecond. The next
  change to that tournament heals it.
  """

  use GenServer

  @table __MODULE__

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`{:ok, status}` on a hit, `:miss` otherwise."
  @spec fetch(String.t()) :: {:ok, atom()} | :miss
  def fetch(slug) do
    case :ets.lookup(@table, slug) do
      [{^slug, status}] -> {:ok, status}
      [] -> :miss
    end
  rescue
    # Not started - a unit test that never booted the application.
    ArgumentError -> :miss
  end

  @doc "A writer's committed status. Overwrites."
  @spec put(String.t(), atom()) :: :ok
  def put(slug, status) do
    :ets.insert(@table, {slug, status})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "A reader's answer to a miss. Never overwrites a writer."
  @spec remember(String.t(), atom()) :: :ok
  def remember(slug, status) do
    :ets.insert_new(@table, {slug, status})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Forgets one slug - for a row that no longer exists (a takedown, a released
  mint). Deleting rather than writing `listed` keeps the table to slugs that
  exist: every slug ever minted and released would otherwise stay here for the
  life of the node. A reader's late `remember/2` can still land after this;
  it can only restore a status the slug HAD, which for a slug with no row and
  no snapshot shows nothing either way, and the next write overwrites it.
  """
  @spec delete(String.t()) :: :ok
  def delete(slug) do
    :ets.delete(@table, slug)
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
