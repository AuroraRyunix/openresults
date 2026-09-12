defmodule OpenResultsWeb.Plugs.Revalidate.PageTable do
  @moduledoc """
  Owns the ETS table behind `OpenResultsWeb.Plugs.Revalidate.Page` - the
  rendered-page cache, `:openresults_page_cache` - for exactly the reason
  `OpenResults.Snapshots.BodyCache` now owns the decoded-snapshot cache's
  table, and `OpenResults.Snapshots.LatestIdCache` owns its own: so the
  table exists before the endpoint accepts its first connection, rather than
  being created lazily by whichever request-handling process happens to
  arrive first - and then disappearing again when THAT process eventually
  exits, taking a table it merely happened to create with it. See
  `OpenResults.Snapshots.BodyCache`'s moduledoc for the failure this closes;
  it is the same one, on the other cache that was still exposed to it.

  ## What this does NOT change

  `Page.get/4`, `Page.put/5` and the table name itself are untouched - they
  already tolerate the table not existing yet, which is still correct for a
  unit test that never boots this supervisor. This module just wins that
  race every time outside of tests, by creating the table before anything
  else can.
  """

  use GenServer

  @table :openresults_page_cache

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
