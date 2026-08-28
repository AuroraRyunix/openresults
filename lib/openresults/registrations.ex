defmodule OpenResults.Registrations do
  @moduledoc """
  Entries submitted for a tournament, held for the arbiter to pull.

  The only payload that travels towards the arbiter, and the only place this
  app holds personal data - an email address, because the arbiter needs to
  reach the player. It is not part of any snapshot and is never rendered.

  This context accepts and holds. It does not validate a player against a
  tournament, does not deduplicate, and does not decide anything: the arbiter
  pulls the list and the arbiter decides, exactly as with a paper entry form.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Envelope
  alias OpenResults.Registrations.Registration
  alias OpenResults.Repo

  @schema_id "openresults/registration"
  @supported_versions [1]

  @doc """
  The schema identifier a registration payload must declare.
  """
  def schema_id, do: @schema_id

  @doc """
  Stores a registration.

  Tolerant in the same way as `OpenResults.Snapshots.ingest/2` and for the
  same reason: a newer form posting a field this server has never seen is
  stored, not refused.
  """
  @spec ingest(term(), keyword()) ::
          {:ok, Registration.t()} | {:error, Envelope.error() | Ecto.Changeset.t()}
  def ingest(payload, opts \\ []) do
    with {:ok, slug} <-
           Envelope.validate(payload, @schema_id, @supported_versions, ["tournament_slug"]) do
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
end
