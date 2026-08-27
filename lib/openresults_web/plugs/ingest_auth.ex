defmodule OpenResultsWeb.Plugs.IngestAuth do
  @moduledoc """
  Bearer-token gate on the publish endpoint.

  The token is the whole of the trust boundary: anything holding it can
  publish a tournament, and nothing else can. Reading it from application
  config rather than a literal is what lets production supply it from
  `OPENRESULTS_INGEST_TOKEN` at boot without it ever entering the repository.

  Fails closed. A missing header, a malformed header, a wrong token and an
  unconfigured server all produce the same 401 with the same body, because a
  caller that can tell "wrong token" from "server has no token" learns
  something it has no business knowing.
  """

  import Plug.Conn

  require Logger

  @unauthorized Jason.encode!(%{error: "unauthorized"})

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, expected} <- configured_token(),
         {:ok, presented} <- presented_token(conn),
         true <- token_matches?(expected, presented) do
      conn
    else
      _rejected -> unauthorized(conn)
    end
  end

  defp configured_token do
    case Application.get_env(:openresults, :ingest_token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _unset ->
        Logger.warning(
          "publish rejected: :ingest_token is not configured, so no token can be accepted"
        )

        :error
    end
  end

  defp presented_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         ["bearer", token] <- header |> String.split(" ", parts: 2) |> downcase_scheme(),
         false <- token == "" do
      {:ok, token}
    else
      _unusable -> :error
    end
  end

  defp downcase_scheme([scheme, token]), do: [String.downcase(scheme), token]
  defp downcase_scheme(other), do: other

  defp token_matches?(expected, presented) do
    # `==` on a secret is a timing oracle: it returns at the first differing
    # byte, so an attacker who can measure the response can recover the token
    # one byte at a time. `secure_compare/2` always looks at everything.
    #
    # Hashing first is not about secrecy - both digests are computed here from
    # values already in memory. It equalises the lengths, because
    # `secure_compare/2` returns early when its arguments differ in size and
    # would otherwise leak how long the real token is.
    Plug.Crypto.secure_compare(
      :crypto.hash(:sha256, expected),
      :crypto.hash(:sha256, presented)
    )
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, @unauthorized)
    |> halt()
  end
end
