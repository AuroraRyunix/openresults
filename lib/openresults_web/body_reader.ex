defmodule OpenResultsWeb.BodyReader do
  @moduledoc """
  `Plug.Conn.read_body/2`, counting the bytes it read.

  Plugged into `Plug.Parsers` in the endpoint so the snapshot size cap for
  installation keys (`OpenResultsWeb.InstallationAccess`) can judge what the
  client actually sent. By the time the router knows which credential a
  request carries, the parser has long since read the body and thrown the
  bytes away; the count is the one fact about them worth keeping.

  The parser's own limit is unchanged - it still stops reading at 8 MB for
  everyone, which is the operator token's limit. The installation cap is
  smaller and is applied afterwards.
  """

  @doc false
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, count(conn, body)}
      {:more, body, conn} -> {:more, body, count(conn, body)}
      other -> other
    end
  end

  defp count(conn, body) do
    Plug.Conn.put_private(
      conn,
      :openresults_body_bytes,
      (conn.private[:openresults_body_bytes] || 0) + byte_size(body)
    )
  end
end
