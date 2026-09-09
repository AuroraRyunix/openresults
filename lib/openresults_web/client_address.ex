defmodule OpenResultsWeb.ClientAddress do
  @moduledoc """
  Which address a request actually came from.

  `conn.remote_ip` is the far end of the TCP connection, and on this
  deployment that is never a visitor. `cloudflared` runs on the same box and
  dials the app over loopback - `docs/deployment.md`, "Reverse proxy / TLS" -
  so every request in the world arrives from 127.0.0.1. Anything keyed on
  `remote_ip` therefore keys the whole internet onto one value, which is how
  the entry form's rate limit came to be a single global bucket that one
  visitor could spend for everybody.

  ## Why a header can be believed here

  A header a client sets is a header a client can lie about, so the only
  question that matters is whether the request really came through the proxy.
  Here that has an answer: the proxy is on the box and dials over loopback, so
  a request whose peer is *not* a loopback address did not come through it and
  its headers are worth nothing. That check runs first, and the headers are
  read only after it passes.

  It is not a general answer. A proxy on a different host arrives from its own
  address, so this would ignore its headers and fall back to keying on the
  proxy - the behaviour that was there before, no better and no worse. That
  topology is what would make `through_proxy?/1` need a configured list of
  trusted addresses rather than the loopback test it is now.

  `cf-connecting-ip` comes first because Cloudflare REPLACES it with the
  address it saw, so a client cannot write through it. `x-forwarded-for` is
  the fallback and its leftmost entry is the convention there - but note that
  behind Cloudflare that entry is whatever the client sent, because Cloudflare
  appends to that header rather than replacing it. Reaching the fallback at
  all means some proxy other than Cloudflare is in front, and there the
  convention holds.

  ## One shape, always

  Every answer is an `:inet` address tuple, including the fallbacks. A header
  that is absent, empty, a list, padded with spaces or outright garbage ends
  at `conn.remote_ip` rather than at `nil` or at the raw string: a caller
  keying on this must never find that malformed requests share a bucket with
  each other, which would be the original bug wearing a different hat.
  """

  alias Plug.Conn

  @doc """
  The visitor's address, as an `:inet` tuple.
  """
  @spec of(Conn.t()) :: :inet.ip_address()
  def of(%Conn{remote_ip: peer} = conn) do
    if through_proxy?(peer) do
      claimed(conn, "cf-connecting-ip") || claimed(conn, "x-forwarded-for") || peer
    else
      peer
    end
  end

  # Loopback, in each of the three shapes it reaches this app in. The last is
  # not decoration: production binds an IPv6 socket on every interface, and an
  # IPv4 client on such a socket arrives v4-mapped as ::ffff:127.0.0.1, which
  # is the same loopback and must be read as one.
  defp through_proxy?({127, _, _, _}), do: true
  defp through_proxy?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp through_proxy?({0, 0, 0, 0, 0, 0xFFFF, high, _low}), do: Bitwise.bsr(high, 8) == 127
  defp through_proxy?(_somewhere_else), do: false

  defp claimed(conn, header) do
    conn
    |> Conn.get_req_header(header)
    |> List.first()
    |> leftmost()
  end

  defp leftmost(nil), do: nil

  # `x-forwarded-for` is a list; `cf-connecting-ip` is a single address, and
  # splitting one that way costs nothing and cannot make it wrong.
  defp leftmost(value) do
    value
    |> String.split(",")
    |> List.first()
    |> String.trim()
    |> address()
  end

  # Parsed rather than trusted as text, which is both how the answer keeps one
  # type and how anything that is not an address is rejected before it can
  # become a key.
  #
  # The strict parse, because the tolerant one reads the abbreviated forms of
  # `inet_aton(3)` - it turns "1.2.3" into 1.2.0.3 and "1" into 0.0.0.1 - and
  # a proxy writes neither. Inventing an address out of a fragment is worse
  # than falling back to the peer, which is where a header nobody can read
  # should end up.
  defp address(""), do: nil

  defp address(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, parsed} -> parsed
      {:error, :einval} -> nil
    end
  end
end
