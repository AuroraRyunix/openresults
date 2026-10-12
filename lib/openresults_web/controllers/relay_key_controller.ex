defmodule OpenResultsWeb.RelayKeyController do
  @moduledoc """
  `POST` and `DELETE /api/tournaments/:slug/relay-keys` - the tournament's
  publisher making, replacing and withdrawing the relay key of its own hall
  box. The contract is `docs/live-boards-api.md`, "A relay key from the
  publisher".

  This is how a box normally gets its key: the arbiter's program (OpenPairings)
  already holds the credentials that publish this tournament, asks here, and
  hands the key to the box. Nobody copies a key and no administrator of this
  server is involved. The admin panel still lists every key and can revoke
  any of them.

  ## Who may

  Exactly who may publish to the slug, checked the same way and in the same
  places: the bearer credential by `OpenResultsWeb.Plugs.IngestAuth` (the
  operator token, or an installation key that owns the slug and is neither
  suspended nor revoked - `OpenResultsWeb.InstallationAccess`, action
  `:relay_key`), and the tournament's own key in `x-openresults-key` when
  the slug has been claimed (`OpenResults.TournamentKeys`). The key check is
  the non-claiming one: asking for a relay key must not claim a slug.

  The tournament must have published and must not be hidden - the conditions
  under which the live endpoint would take the key. A key for a slug that is
  nothing yet would be a credential lying around for whoever publishes there
  first.

  A relay key cannot call this route (it did not opt in to `relay_access`),
  so a stolen box cannot mint its own successor.

  ## Asking twice

  The reply to `POST` carries the key, once; the server keeps a fingerprint.
  Asking again under the same `label` revokes what this publisher made under
  it and returns a new key - see `OpenResults.RelayKeys`, "Two makers". So a
  retry after a lost reply leaves one live key, not two.

  ## Budget

  Six requests per ten minutes per tournament, `POST` and `DELETE` together,
  whoever asks. A key is made once per event and replaced when a box is
  lost; anything asking more often is a loop.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments
  alias OpenResultsWeb.ApiError

  @key_header "x-openresults-key"
  @default_label "publisher"
  @per_window 6
  @window_ms :timer.minutes(10)

  @doc "How many requests one tournament gets per window, for tests."
  def per_window, do: @per_window

  def create(conn, %{"slug" => slug}) do
    with :ok <- budget(slug),
         :ok <- published(slug),
         :ok <- authorize_key(conn, slug),
         label = label(conn.body_params["label"]) || @default_label,
         {:ok, made} <- Moderation.publisher_relay_key(slug, label, actor(conn)) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(:created)
      |> json(%{
        status: "ok",
        slug: slug,
        relay_key: made.key,
        id: made.relay_key.id,
        label: label,
        hint: made.relay_key.hint,
        replaced: length(made.replaced),
        created_at: DateTime.to_iso8601(made.relay_key.inserted_at)
      })
    else
      error -> refuse(conn, error)
    end
  end

  def delete(conn, %{"slug" => slug} = params) do
    with :ok <- budget(slug),
         :ok <- authorize_key(conn, slug),
         {:ok, revoked} <-
           Moderation.publisher_revoke_relay_keys(slug, label(params["label"]), actor(conn)) do
      json(conn, %{status: "ok", slug: slug, revoked: revoked})
    else
      error -> refuse(conn, error)
    end
  end

  defp refuse(conn, {:error, :too_many}), do: ApiError.send(conn, :relay_key_limit)
  defp refuse(conn, {:error, code, extra}), do: ApiError.send(conn, code, extra)
  defp refuse(conn, {:error, code}) when is_atom(code), do: ApiError.send(conn, code)

  defp budget(slug) do
    case RateLimit.take({:relay_key_mint, slug}, limit: @per_window, window_ms: @window_ms) do
      :ok ->
        :ok

      {:denied, retry_in_ms} ->
        {:error, :rate_limited, %{retry_after: ApiError.retry_seconds(retry_in_ms)}}
    end
  end

  defp published(slug) do
    if Tournaments.public_latest(slug), do: :ok, else: {:error, :tournament_not_published}
  end

  defp authorize_key(conn, slug) do
    key =
      case get_req_header(conn, @key_header) do
        [key | _duplicates] -> key
        [] -> nil
      end

    TournamentKeys.authorize_read(slug, key, break_glass: conn.assigns[:credential] == :operator)
  end

  defp actor(conn) do
    case conn.assigns[:credential] do
      {:installation, %{id: id}} -> {:installation, id}
      :operator -> :operator_token
    end
  end

  # What a label may be: text, trimmed, at most 80 characters, no control
  # characters. It is shown in the admin panel and written to the action log.
  defp label(label) when is_binary(label) do
    case label
         |> String.replace(~r/[\x00-\x1F\x7F]/, " ")
         |> String.trim()
         |> String.slice(0, 80) do
      "" -> nil
      text -> text
    end
  end

  defp label(_absent), do: nil
end
