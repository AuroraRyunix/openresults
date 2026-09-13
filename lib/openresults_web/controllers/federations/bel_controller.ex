defmodule OpenResultsWeb.Federations.BelController do
  @moduledoc """
  `GET /api/federations/bel/players` - the Belgian (KBSB/FRBE) roster relay.
  docs/federations-bel.md is the contract.

  Behind the `:ingest` pipeline (`OpenResultsWeb.Plugs.IngestAuth`), which
  accepts either the operator token or an installation key, exactly like
  `GET /api/tournaments/:slug/history` - `InstallationAccess`'s `:bel_players`
  action names what a key may do here (nothing tournament-shaped: this route
  is not tied to any tournament). An unauthenticated request gets the same
  401 as everywhere else on that pipeline.

  `not_configured` (404) when `OPENRESULTS_KBSB_API_URL` /
  `OPENRESULTS_KBSB_API_KEY` are unset - checked before anything else, so it
  answers the same whether or not the caller could otherwise be served,
  matching "the feature is off" rather than "the feature ran and found
  nothing".
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Federations.BEL.{Config, Store}
  alias OpenResults.RateLimit
  alias OpenResultsWeb.ApiError

  # Generous for a legitimate arbiter's machine (which polls at most once a
  # day, see `PairingsEngine.Federations.BEL`'s own sync cadence) and cheap
  # for anyone else to hit: this is one ETS counter before any disk or
  # compression work happens.
  @limit 20
  @window :timer.minutes(1)

  def players(conn, _params) do
    if Config.enabled?() do
      case RateLimit.take({:bel_players, credential_key(conn)}, limit: @limit, window_ms: @window) do
        :ok ->
          serve(conn)

        {:denied, retry_in_ms} ->
          ApiError.send(conn, :rate_limited, %{retry_after: ApiError.retry_seconds(retry_in_ms)})
      end
    else
      ApiError.send(conn, :not_configured)
    end
  end

  defp credential_key(conn) do
    case conn.assigns[:credential] do
      {:installation, installation} -> installation.id
      :operator -> :operator
      _other -> :anonymous
    end
  end

  defp serve(conn) do
    case Store.current() do
      :none ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{updated_at: nil, count: 0, players: []}))

      {:ok, %{etag: etag} = data} ->
        if_none_match = conn |> get_req_header("if-none-match") |> Enum.flat_map(&split_etags/1)

        conn = put_resp_header(conn, "etag", etag)

        if etag in if_none_match do
          send_resp(conn, 304, "")
        else
          send_body(conn, data)
        end
    end
  end

  defp split_etags(header), do: header |> String.split(",") |> Enum.map(&String.trim/1)

  defp send_body(conn, %{body: body, gzip: gzip}) do
    conn = put_resp_header(conn, "vary", "accept-encoding")

    if gzip_acceptable?(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, gzip)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  defp gzip_acceptable?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(String.downcase(&1), "gzip"))
  end
end
