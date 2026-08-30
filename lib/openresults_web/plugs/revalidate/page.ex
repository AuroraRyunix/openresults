defmodule OpenResultsWeb.Plugs.Revalidate.Page do
  @moduledoc """
  The rendered page, kept until the tournament publishes again.

  ## Why this is safe here and would not be elsewhere

  These pages are byte-identical for every reader. There is no login, no
  session, no CSRF token in the layout and no locale on the read path - the
  standings page one spectator gets is the standings page all of them get.
  So a rendered page can be handed to the next reader verbatim rather than
  built again.

  That is not a general Phoenix truth, which is why this cache is bolted to
  the three read routes rather than offered as a helper: the entry form, the
  registration queue and the snapshot API all vary by requester, and caching
  any of them would be a security bug rather than a speed-up.

  ## What it saves

  Rendering a 450-player standings page is ~467 KB of HTML and about 16 ms
  of CPU. At an event that size with a thousand people following, every
  publish is followed by a thousand requests for the same bytes inside
  twenty seconds - roughly 40% of a two-core box, spent rendering one
  document a thousand times.

  With this, a publish costs one render and 999 sends.

  ## Freshness

  Keyed by the snapshot id, so it cannot outlive the publish that replaced
  it: a new id is a different key and the old entries are dropped wholesale.
  Nothing has to remember to invalidate, and there is no window in which
  yesterday's standings could be served - which is the property the
  maintainer rejected CDN caching to protect.

  ## Bounds

  One entry per distinct path visited since the last publish, and the whole
  table is discarded when the snapshot id moves. A 450-player event has one
  large page (the standings) and several hundred small ones (a card per
  player); the cap exists for the pathological case where something walks
  every player page, and drops the table rather than evicting cleverly -
  losing a cache costs a re-render, which is what would have happened
  anyway.
  """

  @table :openresults_page_cache

  # Enough for the standings, every round, and a few hundred player cards -
  # the pages a real audience actually opens between two publishes.
  @max_entries 512

  @doc """
  The stored body for this exact page and version, or `nil`.
  """
  def get(snapshot_id, etag) do
    case :ets.lookup(table(), key(snapshot_id, etag)) do
      [{_key, body}] -> body
      [] -> nil
    end
  rescue
    # Created lazily, so the first read can arrive before it exists. A cache
    # must never be the reason a page fails.
    ArgumentError -> nil
  end

  @doc """
  Stores a rendered body against the version it was rendered from.
  """
  def put(snapshot_id, etag, body) when is_binary(body) do
    table = table()

    # A new snapshot makes every stored page stale at once. Dropping them
    # here rather than letting them age out is what keeps this bounded to
    # one version's worth of pages.
    case :ets.lookup(table, :version) do
      [{:version, ^snapshot_id}] -> :ok
      _older_or_empty -> reset(table, snapshot_id)
    end

    if :ets.info(table, :size) > @max_entries, do: reset(table, snapshot_id)

    :ets.insert(table, {key(snapshot_id, etag), body})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets everything. For tests, and for anything deleting rows behind us."
  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@table)
    end

    :ok
  end

  defp reset(table, snapshot_id) do
    :ets.delete_all_objects(table)
    :ets.insert(table, {:version, snapshot_id})
  end

  defp key(snapshot_id, etag), do: {snapshot_id, etag}

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      ref ->
        ref
    end
  rescue
    # Two processes racing to create it; whoever lost uses the winner's.
    ArgumentError -> @table
  end
end
