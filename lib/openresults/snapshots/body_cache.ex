defmodule OpenResults.Snapshots.BodyCache do
  @moduledoc """
  Owns the ETS table behind `OpenResults.Snapshots`' decoded-snapshot cache -
  the one `cached/2` reads and writes as `:openresults_snapshot_cache` - for
  exactly the reason `OpenResults.Snapshots.LatestIdCache` gives for owning
  its own table: so it exists before the endpoint accepts its first
  connection, rather than being created lazily by whichever request happens
  to arrive first.

  ## The failure this closes

  Before this module existed, `Snapshots.cached/2` created its table lazily,
  from inside whichever request-handling process got there first - and an
  ETS table's lifetime is tied to the process that created it: when that
  process exits, the table goes with it, unless ownership was explicitly
  handed off. A Bandit connection process is exactly the kind of process
  that exits routinely - the client disconnects, `Finch.TransportError`
  closes it, a keepalive connection cycles - so the table this cache depends
  on could vanish and reappear repeatedly over the life of a busy server, not
  once at boot.

  That is silent and self-healing in isolation (a vanished table just means
  the next reader re-queries and re-populates it - see `cached/2`), but under
  load it reproduces the exact failure `LatestIdCache` was built to prevent:
  every request whose table lookup misses falls through to a real query
  through `OpenResults.Repo`, and if the table disappears while hundreds of
  requests are in flight, all of them miss at once and the five-connection
  pool sees the same burst of simultaneous queries that
  `docs/load-test-2026-09-12.md` §5 first diagnosed - measured directly in
  this repo's own load test re-run: `DBConnection.ConnectionError` reappeared
  by the thousand at exactly the concurrency levels where it should have
  stayed gone, with queue waits over six seconds, on a table that a fresh
  `:ets.new/2` shows was being recreated mid-ramp rather than held for the
  run's duration.

  This module is the same fix `LatestIdCache` already is, applied to the
  other cache that was still exposed to it: own the table from a process
  that is part of the supervision tree and only ever stops when the node
  does, so the table's existence stops being a question at all.

  ## What this does NOT change

  `OpenResults.Snapshots.cached/2`, `lookup/1` and the table name itself are
  untouched - they already tolerate the table not existing yet (the
  lazy-creation path in `cached/2`'s private `table/0` is still there, and
  still correct for a unit test that never boots this supervisor). This
  module just wins that race every time outside of tests, by creating the
  table before anything else can.
  """

  use GenServer

  @table :openresults_snapshot_cache

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _already_exists ->
        :ok
    end

    {:ok, opts}
  end
end
