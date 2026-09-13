defmodule OpenResults.Registrations do
  @moduledoc """
  Entries submitted for a tournament, held for the arbiter to pull.

  The only payload that travels towards the arbiter, and the only place this
  app holds personal data - an email address, because the arbiter needs to
  reach the player. It is not part of any snapshot and is never rendered.

  This context accepts and holds. It does not validate a player against a
  tournament, does not deduplicate, and does not decide anything: the arbiter
  pulls the list and the arbiter decides, exactly as with a paper entry form.

  ## Bounds

  The one table a member of the public can grow, and until `ingest/2` began
  counting it grew without a bound: entries could be piled into a
  tournament's queue until the list the arbiter pulls was too long to open,
  with the entries of the people who actually wanted to play somewhere in the
  middle of it.

  The cap is per tournament, for the reason
  `OpenResultsWeb.Plugs.Revalidate.Page` sets out about its own: several
  events run at once, and one of them having a bad day must not shut the
  others out. A global cap would let one tournament's flood refuse every
  other tournament's entries, which is a worse failure than the one being
  prevented.

  What it counts is rows, and every row here is pending by construction. This
  server has no notion of an entry being handled - that is a fact about the
  arbiter's machine and is kept there, which is why `list_for_tournament/1`
  returns everything every time - so nothing in this table is ever anything
  but waiting, and there are two ways out: `delete_all_for/1` under a
  takedown, and `delete_expired/2` once the tournament is over - see
  `OpenResults.Retention`.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Envelope
  alias OpenResults.Registrations.Registration
  alias OpenResults.Repo
  alias OpenResults.Snapshots.Snapshot

  @schema_id "openresults/registration"
  @supported_versions [1]

  # Entries one tournament may have waiting. Well past any field this site has
  # served - the page cache calls 450 players its large case - so a tournament
  # that reaches it is not a tournament having a busy morning. Beyond it the
  # queue has stopped being a queue, and an arbiter whose event genuinely
  # fills it can still enter people by hand, which is what the closed form
  # already tells people to ask for.
  @max_queue 1_000

  @doc """
  The schema identifier a registration payload must declare.
  """
  def schema_id, do: @schema_id

  @doc """
  Stores a registration.

  Tolerant in the same way as `OpenResults.Snapshots.ingest/2` and for the
  same reason: a newer form posting a field this server has never seen is
  stored, not refused.

  Refuses with `{:error, :queue_full}` once the tournament already holds
  `#{@max_queue}` entries - see "Bounds" above for why that is counted per
  tournament. `:max_queue` overrides the cap, which is how the tests prove
  the bound without inserting a thousand rows to reach it.
  """
  @spec ingest(term(), keyword()) ::
          {:ok, Registration.t()} | {:error, :queue_full | Envelope.error() | Ecto.Changeset.t()}
  def ingest(payload, opts \\ []) do
    with {:ok, slug} <-
           Envelope.validate(payload, @schema_id, @supported_versions, ["tournament_slug"]),
         :ok <- room_for_one_more(slug, Keyword.get(opts, :max_queue, @max_queue)) do
      %Registration{}
      |> Registration.changeset(%{
        tournament_slug: slug,
        version: Map.get(payload, "version"),
        # The server's clock, deliberately not the envelope's `received_at`.
        # That field is a claim by an unauthenticated public submitter and is
        # trivially forged; it stays readable inside the payload, but the
        # column the arbiter sorts by is the one this server stamped.
        received_at: Keyword.get_lazy(opts, :received_at, &DateTime.utc_now/0),
        payload: payload
      })
      |> Repo.insert()
    end
  end

  # Counted, then inserted, rather than settled in one statement: two entries
  # arriving in the same instant can carry a queue a row or two past the cap.
  # That is the tolerance `OpenResults.RateLimit`'s fixed window already
  # takes, and for the same reason - the bound exists to stop unbounded
  # growth, and being exact about its last row would cost a transaction on
  # every entry to buy nothing anybody can perceive.
  defp room_for_one_more(slug, max) do
    if queue_length(slug) < max, do: :ok, else: {:error, :queue_full}
  end

  defp queue_length(slug) do
    Repo.aggregate(from(r in Registration, where: r.tournament_slug == ^slug), :count)
  end

  @doc """
  Every registration held for a tournament, oldest first.

  Oldest first because entry order is what decides a capped field, and an
  arbiter reading the list is reading a queue.
  """
  @spec list_for_tournament(String.t()) :: [Registration.t()]
  def list_for_tournament(slug) do
    from(r in Registration,
      where: r.tournament_slug == ^slug,
      order_by: [asc: r.received_at, asc: r.id]
    )
    |> Repo.all()
  end

  @doc """
  Deletes every registration held for a tournament, returning how many went.

  Part of a takedown, and the part that actually removes personal data: a
  snapshot holds names an arbiter chose to publish, but this table holds email
  addresses typed by members of the public who expected only the organiser to
  read them. A takedown that removed the snapshots and left this behind would
  leave the most sensitive rows in the database attached to a tournament that
  no longer exists to find them by.

  Only ever called from `OpenResults.Takedown.purge/1`.
  """
  @spec delete_all_for(String.t()) :: non_neg_integer()
  def delete_all_for(slug) do
    {count, _returned} =
      from(r in Registration, where: r.tournament_slug == ^slug) |> Repo.delete_all()

    count
  end

  @doc """
  Deletes the registrations of every tournament that has been over for `days`,
  returning how many rows went.

  Over is judged from the tournament's latest snapshot: its `end_date` when it
  has a usable one, and otherwise the last time it published - but never for
  a tournament whose `start_date` is still in the future, which has plainly
  not happened yet. A tournament that has never published has nothing to
  judge by and keeps its queue.

  Only ever called from `OpenResults.Retention`.
  """
  @spec delete_expired(DateTime.t(), pos_integer()) :: non_neg_integer()
  def delete_expired(%DateTime{} = now, days) when is_integer(days) do
    today = DateTime.to_date(now)

    latest =
      from s in Snapshot,
        group_by: s.tournament_slug,
        select: %{slug: s.tournament_slug, id: max(s.id)}

    queued = from r in Registration, distinct: true, select: %{slug: r.tournament_slug}

    from(q in subquery(queued),
      join: l in subquery(latest),
      on: l.slug == q.slug,
      join: s in Snapshot,
      on: s.id == l.id,
      select: {
        q.slug,
        fragment("json_extract(?, '$.tournament.end_date')", s.payload),
        fragment("json_extract(?, '$.tournament.start_date')", s.payload),
        s.received_at
      }
    )
    |> Repo.all()
    |> Enum.filter(fn {_slug, end_date, start_date, published_at} ->
      expired?(now, today, days, iso_date(end_date), iso_date(start_date), published_at)
    end)
    |> Enum.reduce(0, fn {slug, _end, _start, _published}, count ->
      count + delete_all_for(slug)
    end)
  end

  defp expired?(_now, today, days, %Date{} = end_date, _start_date, _published_at),
    do: Date.compare(Date.add(end_date, days), today) != :gt

  defp expired?(now, today, days, nil, start_date, published_at) do
    not_started? = match?(%Date{}, start_date) and Date.compare(start_date, today) == :gt

    not not_started? and
      DateTime.compare(DateTime.add(published_at, days * 86_400, :second), now) != :gt
  end

  defp iso_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp iso_date(_absent), do: nil
end
