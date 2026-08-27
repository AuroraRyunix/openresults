defmodule OpenResultsWeb.SnapshotController do
  @moduledoc """
  Ingest and read-back of published snapshots.

  Three routes. `create` is the trust boundary and is token-gated. `show`
  serves the CURRENT document and is open, because that document contains
  nothing that was withheld - the withholding happened before it was built.
  `history` serves earlier documents and is token-gated, which is the whole
  point of the split.

  Withholding holds for the current document ONLY. The table is append-only,
  so an earlier row can contain a round the arbiter has since RETRACTED - a
  wrong result entered, republished without it - or a board they have since
  hidden. Serving those by timestamp on an open endpoint hands back exactly
  what the arbiter withdrew, and it was reproducible: publish rounds 1,2,3,5,
  retract round 3, and `?at=` returned round 3 with its boards intact while
  the page one link away correctly 404'd.

  That is the same failure OpenPairings shipped this week - a backup
  restoring every hidden board into view - through a different door. The
  append-only table is right and stays; its public reachability was the bug.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Snapshots

  @doc """
  `POST /api/snapshots` - accepts a published snapshot.
  """
  def create(conn, _params) do
    # `conn.body_params`, not the `params` Phoenix hands in. Those are the body
    # merged with the query string, and the stored document has to be the body
    # verbatim - otherwise `?rounds=[]` on the publish URL would end up inside
    # a payload that is meant to be exactly what the arbiter's machine built.
    case Snapshots.ingest(conn.body_params) do
      {:ok, snapshot} ->
        json(conn, %{
          status: "ok",
          slug: snapshot.tournament_slug,
          received_at: DateTime.to_iso8601(snapshot.received_at)
        })

      {:error, reason} when is_atom(reason) ->
        reject(conn, reason)

      {:error, %Ecto.Changeset{} = changeset} ->
        reject(conn, :invalid, changeset_detail(changeset))
    end
  end

  @doc """
  `GET /api/tournaments/:slug` - returns the CURRENT stored payload.

  `at` is refused here rather than ignored. Ignoring it would answer a
  question about the past with a document about the present, which is worse
  than saying no: a caller asking for 14:00 and getting 18:00 without being
  told has no way to notice. History lives on the authenticated route.
  """
  def show(conn, %{"slug" => _slug} = params) when is_map_key(params, "at") do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "history_requires_auth",
      detail: "earlier snapshots may contain rounds or boards since retracted"
    })
  end

  def show(conn, %{"slug" => slug}) do
    case {:ok, Snapshots.latest(slug)} do
      {:ok, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", slug: slug})

      {:ok, snapshot} ->
        # The payload as stored, byte for byte in meaning. A response that
        # reshaped it would be a second, undocumented contract.
        json(conn, snapshot.payload)
    end
  end

  @doc """
  `GET /api/tournaments/:slug/history?at=<ISO 8601>` - the snapshot that was
  current at that instant. Token-gated, because an earlier document can hold
  a round or a board the arbiter has since withdrawn.

  "What did the standings say at 14:00" is an ARBITER's question, and this is
  where an arbiter asks it.
  """
  def history(conn, %{"slug" => slug} = params) do
    case resolve_at(Map.get(params, "at")) do
      {:ok, instant} ->
        case Snapshots.as_of(slug, instant) do
          nil -> conn |> put_status(:not_found) |> json(%{error: "not_found", slug: slug})
          snapshot -> json(conn, snapshot.payload)
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "bad_at", detail: "`at` must be an ISO 8601 instant"})
    end
  end

  defp resolve_at(nil), do: :error

  defp resolve_at(at) do
    case DateTime.from_iso8601(at) do
      {:ok, instant, _utc_offset} -> {:ok, instant}
      {:error, _reason} -> :error
    end
  end

  defp reject(conn, reason, detail \\ nil) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Atom.to_string(reason), detail: detail || detail_for(reason)})
  end

  defp detail_for(:not_an_object), do: "the body must be a JSON object"
  defp detail_for(:wrong_schema), do: "`schema` must be #{Snapshots.schema_id()}"
  defp detail_for(:unknown_version), do: "`version` is not a version this server understands"
  defp detail_for(:missing_slug), do: "`tournament.slug` is required"

  defp changeset_detail(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
