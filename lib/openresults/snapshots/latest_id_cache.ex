defmodule OpenResults.Snapshots.LatestIdCache do
  @moduledoc """
  The one number `OpenResultsWeb.Plugs.Revalidate` needs on every request,
  kept out of the database entirely.

  ## The cost this removes

  `OpenResults.Snapshots.latest_id/1` used to be a live `SELECT ... LIMIT 1`
  through `OpenResults.Repo` on every single read request - a standings page,
  a round, a player card, and every conditional re-poll that ends in a bare
  `304` without ever touching a renderer. Cheap alone (a primary-key lookup),
  but never skipped, which is what a 2026-09-12 load test found breaking the
  five-connection Ecto pool at a few hundred concurrent readers: see
  `docs/load-test-2026-09-12.md` §5. This cache is the fix - a slug whose id
  is already known costs an ETS lookup and nothing else.

  ## Why supervision, not lazy `:ets.new/2`

  `OpenResults.Snapshots`' own body cache and
  `OpenResultsWeb.Plugs.Revalidate.Page` both create their table on first
  use and treat `ArgumentError` from a not-yet-created table as a miss -
  correct for them, because they sit behind a cache MISS that already falls
  back to a query. Wrapping this cache's `:ets.new/2` the same lazy way would
  work identically, but this module is started under
  `OpenResults.Application` anyway (see there) rather than left lazy,
  precisely so the table's existence is never in question by the time the
  endpoint accepts its first connection - one fewer thing for a reader of
  this code to have to convince themselves is safe under concurrent boot.

  ## Reading

  `fetch/1` is the only way in from a request. A hit trusts the cache
  completely and touches nothing else - that is the entire point. A miss
  means "ask the database and remember the answer", which
  `OpenResults.Snapshots.latest_id/1` does; this module never queries
  anything itself.

  ## Writing

  `put/2` is called from exactly one place: `OpenResults.Snapshots.store/3`,
  the instant a publish inserts a new row and knows its id. That is the
  publish this cache exists to make every OTHER reader see immediately - a
  cached id that lagged behind the database by even one request would be
  the exact bug this table must never have: a `304` for a page that has
  already been superseded.

  A plain overwrite, not a compare-and-swap. SQLite has one writer, so two
  publishes to the same slug are already serialised at the database - the
  first commits and releases the write lock before the second even begins.
  The only theoretical inversion left is scheduling, not data: the second
  writer's Elixir process could in principle run its `put/2` before the
  first writer's process gets scheduled to run its own, leaving the cache
  briefly older than the row that already exists. Publishes are one arbiter
  publishing one tournament, not a swarm, so two genuinely concurrent
  publishes to the very same slug is already a rare event, and the reader
  cost of losing this particular race is a `200` instead of a `304` for the
  next poll - not silence, not a wrong document, just a cache that heals
  itself on the very next revalidation, and certainly by the next publish's
  own overwrite. That is a trade this module makes deliberately, in favour
  of the exact-equality writes every other cache in this codebase already
  uses (see `OpenResultsWeb.Plugs.Revalidate.Page.put/5`) rather than
  inventing a compare-and-swap for a window this narrow.

  ## Forgetting

  `forget/1` is for `OpenResults.Snapshots.delete_all_for/1` - a takedown,
  where "no snapshot" is the truth from that moment on. Leaving a stale
  positive id cached after every row for a slug is deleted would be the same
  bug as above wearing a different hat: a reader told the tournament is
  still at some id N when the database now holds none at all.

  Unpublished slugs are never cached at all - `put/2` is only ever called
  with an id, so a miss for a slug that has never published simply queries
  the database again next time, which is cheap and correct: that is not the
  hot path this cache exists for.
  """

  use GenServer

  @table __MODULE__

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cached latest snapshot id for `slug`.

  `{:ok, id}` on a hit, trusted without consulting anything else. `:miss`
  when nothing is cached - a cold cache, or a slug that has never published -
  and the caller must ask the database.
  """
  @spec fetch(String.t()) :: {:ok, integer()} | :miss
  def fetch(slug) do
    case :ets.lookup(@table, slug) do
      [{^slug, id}] -> {:ok, id}
      [] -> :miss
    end
  end

  @doc """
  Records `id` as the latest known snapshot for `slug`.

  Called by `OpenResults.Snapshots.store/3` the moment a publish inserts a
  new row, and by `OpenResults.Snapshots.latest_id/1` to remember what a
  cache-miss query just found. See "Writing" above for why this overwrites
  unconditionally rather than comparing.
  """
  @spec put(String.t(), integer()) :: :ok
  def put(slug, id) when is_integer(id) do
    :ets.insert(@table, {slug, id})
    :ok
  end

  @doc """
  Forgets `slug` entirely, for a takedown that deleted every row it had.
  """
  @spec forget(String.t()) :: :ok
  def forget(slug) do
    :ets.delete(@table, slug)
    :ok
  end

  @doc """
  Forgets everything cached. For tests, and for anything else that changes
  rows behind this module's back.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl GenServer
  def init(opts) do
    # Public and named: every request reads and writes this table directly,
    # in its own process, without going through this GenServer at all - it
    # exists only to own the table and create it before anything can ask.
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
