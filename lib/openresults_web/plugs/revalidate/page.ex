defmodule OpenResultsWeb.Plugs.Revalidate.Page do
  @moduledoc """
  The rendered page, kept until the tournament publishes again.

  ## Why this is safe here and would not be elsewhere

  These pages are byte-identical for every reader who asks for them the same
  way. There is no login, no session and no CSRF token in the layout - the
  standings page one spectator gets is the standings page all of them get.
  So a rendered page can be handed to the next reader verbatim rather than
  built again.

  That is not a general Phoenix truth, which is why this cache is bolted to
  the three read routes rather than offered as a helper: the entry form, the
  registration queue and the snapshot API all vary by requester, and caching
  any of them would be a security bug rather than a speed-up.

  ## The one thing that does vary

  The language. It was not always in the key, and the day the pages became
  translatable it had to be: a Dutch reader's rendered page sat under a key
  a French request matched exactly, so whoever asked first decided what
  everybody after them read. It failed silently, intermittently, and only
  for the second reader - which is the worst shape a caching bug can take.

  So the locale is part of the identity here AND part of the ETag, which
  `OpenResultsWeb.Plugs.Revalidate` builds. Either alone would do the job as
  the code stands today, since the ETag is itself part of this key; both are
  here because the two are separate arguments. This key says "a page is a
  tournament, a version, a language and an address"; the ETag says the same
  thing to the reader's own browser, which must not answer 304 to a request
  in a language it has never fetched.

  ## What it saves

  Rendering a 450-player standings page is ~467 KB of HTML and about 16 ms
  of CPU. At an event that size with a thousand people following, every
  publish is followed by a thousand requests for the same bytes inside
  twenty seconds - roughly 40% of a two-core box, spent rendering one
  document a thousand times.

  With this, a publish costs one render and 999 sends.

  ## Freshness

  Keyed by the snapshot id and scoped to the tournament that produced it, so
  a page cannot outlive the publish that replaced it, and a publish cannot
  touch a page it has nothing to do with: a new id for one tournament is a
  different key for that tournament alone, and it is only that tournament's
  old entries that get dropped. Nothing has to remember to invalidate, and
  there is no window in which yesterday's standings could be served - which
  is the property the maintainer rejected CDN caching to protect.

  Scoping by tournament is what keeps this working under load rather than
  against it. Without the tournament in the key, one arbiter's publish would
  discard every **other** live tournament's warm cache too - collapsing the
  hit rate to near zero exactly when several events running at once is the
  scenario this cache exists for.

  ## Bounds

  One entry per distinct path visited since a tournament's last publish, and
  the cap applies per tournament rather than to the table as a whole, so one
  event having a busy day cannot evict another event's cache. A 450-player
  event has one large page (the standings) and several hundred small ones (a
  card per player); the cap exists for the pathological case where something
  walks every player page, and drops that tournament's own entries rather
  than evicting cleverly - losing a cache costs a re-render, which is what
  would have happened anyway.
  """

  @table :openresults_page_cache

  # Enough for the standings, every round, and a few hundred player cards -
  # the pages a real audience actually opens between two publishes. Applied
  # per tournament: several tournaments each holding this many entries is the
  # point, not a leak - see "Bounds" above.
  @max_entries 512

  @doc """
  The stored body for this exact tournament, page, version and language, or
  `nil`.
  """
  def get(slug, snapshot_id, locale, etag) do
    case :ets.lookup(table(), key(slug, snapshot_id, locale, etag)) do
      [{_key, body}] -> body
      [] -> nil
    end
  rescue
    # Created lazily, so the first read can arrive before it exists. A cache
    # must never be the reason a page fails.
    ArgumentError -> nil
  end

  @doc """
  Stores a rendered body against the tournament, version and language it was
  rendered from.
  """
  def put(slug, snapshot_id, locale, etag, body) when is_binary(body) do
    table = table()

    # A new snapshot makes every stored page of THIS tournament stale at
    # once. Dropping them here rather than letting them age out is what
    # keeps this bounded to one version's worth of pages - and only this
    # tournament's pages, so somebody else's publish is not our problem.
    case :ets.lookup(table, version_key(slug)) do
      [{_key, ^snapshot_id}] -> :ok
      _older_or_empty -> reset(table, slug, snapshot_id)
    end

    if count(table, slug) > @max_entries, do: reset(table, slug, snapshot_id)

    :ets.insert(table, {key(slug, snapshot_id, locale, etag), body})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Drops every stored page of ONE tournament, in every language - the same
  sweep a publish triggers in `put/5`, for the one change that alters a page
  without changing its snapshot id: moderation changing a tournament's
  visibility (`OpenResults.Tournaments`). A pending page carries `noindex`
  and a listed one does not, so the old body must not be served under the
  new status.
  """
  def forget(slug) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      table ->
        :ets.match_delete(table, {{slug, :_, :_, :_}, :_})
        :ets.delete(table, version_key(slug))
        :ok
    end
  end

  @doc "Forgets everything, every tournament included. For tests, and for anything deleting rows behind us."
  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@table)
    end

    :ok
  end

  # Wipes one tournament's entries and restamps its version, leaving every
  # other tournament in the table untouched - the whole reason the key and
  # the version row both carry the tournament now.
  defp reset(table, slug, snapshot_id) do
    :ets.match_delete(table, {{slug, :_, :_, :_}, :_})
    :ets.insert(table, {version_key(slug), snapshot_id})
  end

  # A full-table scan filtered to one tournament, same as `reset/3`'s
  # `match_delete`. Fine at these sizes - hundreds of rows per tournament,
  # not the thing that would ever justify a second index just to avoid it.
  defp count(table, slug) do
    :ets.select_count(table, [{{{slug, :_, :_, :_}, :_}, [], [true]}])
  end

  defp key(slug, snapshot_id, locale, etag), do: {slug, snapshot_id, locale, etag}

  defp version_key(slug), do: {:version, slug}

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
