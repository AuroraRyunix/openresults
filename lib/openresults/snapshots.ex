defmodule OpenResults.Snapshots do
  @moduledoc """
  Storage and retrieval of published tournament snapshots.

  The whole of this app's write path. It takes a document an arbiter's machine
  produced, checks the envelope, and keeps the document verbatim. It does not
  interpret rounds, boards or standings, and it never computes a placing - the
  arbiter's screen and the public page have to agree, and the only way to
  guarantee that is to have exactly one thing doing the arithmetic.

  What is absent from a payload stays absent. An unpublished round and a
  hidden board are withheld at build time on the arbiter's machine, so there
  is nothing here to filter and nothing here to leak.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Envelope
  alias OpenResults.Repo
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.TournamentKeys

  @schema_id "openresults/snapshot"

  # Every envelope version this server understands. A list rather than a
  # ceiling: see OpenResults.Envelope.
  @supported_versions [1]

  @doc """
  The schema identifier a snapshot payload must declare.
  """
  def schema_id, do: @schema_id

  @doc """
  Stores a published snapshot.

  `payload` is the decoded JSON document, exactly as it arrived. Unknown
  fields - at the top level or buried anywhere inside - are stored, not
  rejected: that tolerance is the reason the contract can add fields without
  stranding older servers.

  Returns `{:error, reason}` for the four things that are genuinely
  unstorable: `:not_an_object`, `:wrong_schema`, `:unknown_version`,
  `:missing_slug`.

  ## Options

    * `:key` - the tournament key the request presented, or `nil`. Checked by
      `OpenResults.TournamentKeys`, which also claims an unclaimed slug on a
      first publish. `{:error, :key_required}` and `{:error, :key_mismatch}`
      come from there.

    * `:received_at` - the server's clock, injectable for tests.

  The key is checked AFTER the envelope, because the slug it authorises
  against is inside the envelope and there is nothing to authorise until it
  has been read. It is checked BEFORE anything is written, including before
  the idempotent-repeat comparison below: a request with the wrong key must
  change nothing, and it must not learn from a "nothing changed" answer what
  the tournament currently holds.
  """
  @spec ingest(term(), keyword()) ::
          {:ok, Snapshot.t()}
          | {:error, Envelope.error() | TournamentKeys.error() | Ecto.Changeset.t()}
  def ingest(payload, opts \\ []) do
    with {:ok, slug} <-
           Envelope.validate(payload, @schema_id, @supported_versions, ["tournament", "slug"]),
         :ok <- TournamentKeys.authorize_publish(slug, Keyword.get(opts, :key)) do
      received_at = Keyword.get_lazy(opts, :received_at, &DateTime.utc_now/0)
      store(slug, payload, received_at)
    end
  end

  defp store(slug, payload, received_at) do
    case latest(slug) do
      # A publish is idempotent by design: the document is whole, so re-sending
      # it after a timeout means the same thing as sending it once. Collapsing
      # a byte-identical repeat keeps the history a record of what changed
      # rather than a record of how flaky the hall's wifi was. If the round
      # trip through JSON ever perturbs a value the comparison misses, the
      # fallback is an extra identical row, which reads back the same.
      %Snapshot{payload: ^payload} = unchanged ->
        {:ok, unchanged}

      _new_or_changed ->
        %Snapshot{}
        |> Snapshot.changeset(%{
          tournament_slug: slug,
          version: Map.get(payload, "version"),
          source_app: source_field(payload, "app"),
          source_version: source_field(payload, "version"),
          published_at: Envelope.claimed_time(payload, "published_at"),
          received_at: received_at,
          payload: payload
        })
        |> Repo.insert()
    end
  end

  defp source_field(payload, key) do
    case Map.get(payload, "source") do
      source when is_map(source) ->
        case Map.get(source, key) do
          value when is_binary(value) -> value
          _absent_or_not_a_string -> nil
        end

      _absent_or_not_an_object ->
        nil
    end
  end

  @doc """
  The current snapshot for a tournament, or `nil`.

  What the public page renders. Newest by the server's clock, with the id
  breaking a tie, because two publishes can land in the same microsecond and
  the row that arrived second is the later one by definition.
  """
  @spec latest(String.t()) :: Snapshot.t() | nil
  def latest(slug) do
    case latest_id(slug) do
      nil -> nil
      id -> cached(slug, id)
    end
  end

  # One decode per published version, rather than one per reader.
  #
  # `OpenResultsWeb.Plugs.Revalidate` already makes an unchanged poll cost a
  # primary-key lookup, which is the common case and 566x cheaper than a
  # render. What it cannot help is the moment that actually matters: a round
  # finishes, the arbiter publishes, and every phone in the hall asks for the
  # new page inside the next twenty seconds. Each of those is a genuine 200,
  # and without this each would decode the same ~580 KB document again.
  #
  # Keyed by SLUG and validated by id, so a new publish is picked up on the
  # next request rather than needing anything to remember to invalidate. The
  # id comes from `latest_id/1`, which the caller has usually just paid for
  # anyway.
  #
  # ETS copies on read, so this saves the decode and not the copy - the
  # decode is the expensive half. Bounded by the number of tournaments being
  # read, one entry each, and an entry is replaced rather than added when a
  # tournament publishes again.
  defp cached(slug, id) do
    case lookup(slug) do
      %Snapshot{id: ^id} = hit ->
        hit

      _miss_or_stale ->
        snapshot = slug |> for_slug() |> limit(1) |> Repo.one()
        if snapshot, do: :ets.insert(table(), {slug, snapshot})
        snapshot
    end
  end

  defp lookup(slug) do
    case :ets.lookup(table(), slug) do
      [{^slug, snapshot}] -> snapshot
      [] -> nil
    end
  rescue
    # The table is created lazily, so the very first read can arrive before
    # it exists. A cache must never be the reason a page fails.
    ArgumentError -> nil
  end

  @cache :openresults_snapshot_cache

  defp table do
    case :ets.whereis(@cache) do
      :undefined ->
        :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])

      ref ->
        ref
    end
  rescue
    # Two processes racing to create it: whoever lost just uses the winner's.
    ArgumentError -> @cache
  end

  @doc """
  Forgets everything cached. For tests, and for anything that deletes rows
  behind this module's back.
  """
  def clear_cache do
    case :ets.whereis(@cache) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@cache)
    end

    :ok
  end

  @doc """
  The id of the newest snapshot for `slug`, without loading it.

  The whole point is what it does NOT select. A published document is up to
  ~580 KB of JSON, and `latest/1` decodes all of it on every page view - so
  answering "has this changed since you last asked" by loading the snapshot
  would cost exactly what it is trying to save.

  The id alone identifies a version: the table appends, one row per changed
  publish, and a byte-identical re-send is collapsed rather than inserted
  (see `store/3`). So a reader holding id 41 and finding 41 still current is
  holding the current document, and nothing has to be read to prove it.
  """
  @spec latest_id(String.t()) :: integer() | nil
  def latest_id(slug) do
    slug
    |> for_slug()
    |> limit(1)
    |> select([s], s.id)
    |> Repo.one()
  end

  @doc """
  The snapshot that was current at `instant`, or `nil` if none had arrived yet.

  The reason the table appends. "What did the standings say at 14:00" is a
  question that follows a disputed result, and the contract forbids
  recomputing the answer, so it has to have been kept.
  """
  @spec as_of(String.t(), DateTime.t()) :: Snapshot.t() | nil
  def as_of(slug, %DateTime{} = instant) do
    slug
    |> for_slug_as_of(instant)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Every snapshot held for a tournament, newest first.
  """
  @spec history(String.t()) :: [Snapshot.t()]
  def history(slug) do
    slug
    |> for_slug()
    |> Repo.all()
  end

  @doc """
  The current snapshot of every tournament that has ever published, by slug.

  For an index page. Picks the highest id per slug rather than the latest
  `received_at`, so a server clock that steps backwards cannot resurrect a
  superseded snapshot as the current one.
  """
  @spec list_current() :: [Snapshot.t()]
  def list_current do
    newest_per_slug =
      from s in Snapshot,
        group_by: s.tournament_slug,
        select: max(s.id)

    from(s in Snapshot,
      where: s.id in subquery(newest_per_slug),
      order_by: [asc: s.tournament_slug]
    )
    |> Repo.all()
  end

  @doc """
  Deletes EVERY snapshot held for a tournament, returning how many went.

  Every one, not the current one. The table appends and `/history` serves
  earlier rows by `?at=`, so removing only the newest row would empty the
  public pages while leaving the whole event - and any round the arbiter had
  already retracted - readable by anyone holding the ingest token.

  Only ever called from `OpenResults.Takedown.purge/1`, which is what makes
  sure the registration queue and the key claim go in the same breath.
  """
  @spec delete_all_for(String.t()) :: non_neg_integer()
  def delete_all_for(slug) do
    {count, _returned} =
      from(s in Snapshot, where: s.tournament_slug == ^slug) |> Repo.delete_all()

    count
  end

  # Newest by INSERTION, not by timestamp. `received_at` is wall-clock and
  # wall-clock steps backwards - an NTP correction is enough - and a
  # superseded document winning that comparison is permanent: nothing
  # re-publishes to fix it, and no error is raised anywhere.
  #
  # `list_current/0` already defended itself this way with `max(s.id)` and
  # said so in its own docstring; the defence was simply never applied here,
  # so the index page and every public page could disagree about which
  # document is current. Reproduced with two publishes stamped 12:00:00 then
  # 11:59:59: the index linked to the new name, the standings page it linked
  # to served the old document.
  defp for_slug(slug) do
    from s in Snapshot,
      where: s.tournament_slug == ^slug,
      order_by: [desc: s.id]
  end

  # `as_of/2` is the one caller that legitimately reasons about wall-clock,
  # because "what was current at 14:00" is a question about time. It still
  # ORDERS by id: among rows stamped at or before the instant, the one
  # inserted last is the one that was current.
  defp for_slug_as_of(slug, instant) do
    from s in Snapshot,
      where: s.tournament_slug == ^slug and s.received_at <= ^instant,
      order_by: [desc: s.id]
  end
end
