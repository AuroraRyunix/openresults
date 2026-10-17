defmodule OpenResultsWeb.Plugs.ShortHost do
  @moduledoc """
  The short-link host (`pairings.cloud`): a tournament's short address, as
  printed on a poster or sent in a message, moves to the same page here.

  When `config :openresults, :host_policy` names a `:short_host` and the
  request arrives on it:

    * `/` and `/t/...` (`/t/<slug>`, `/t/<slug>/round/3`, the hall display,
      ...) get a `301` to the same path and query on the canonical host;
    * anything else is an empty `404` - this host exists to forward tournament
      links, and must not serve the application, the API or the admin panel
      under a second name.

  Only `GET` and `HEAD` are forwarded; other methods get the same `404`.

  Served here rather than by OpenPairings because the target is a page of this
  application: `/t/:slug` is this router's route, OpenPairings has served no
  public page since the split, and a desktop copy of OpenPairings has no
  public hostname to receive a short link at all.

  With no `:short_host` configured (the default) the plug does nothing.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    policy = Application.get_env(:openresults, :host_policy, [])
    short = policy[:short_host]
    canonical = policy[:canonical]

    if is_binary(short) and is_binary(canonical) and String.downcase(conn.host || "") == short do
      forward(conn, canonical)
    else
      conn
    end
  end

  defp forward(%Plug.Conn{method: method, request_path: path} = conn, canonical)
       when method in ["GET", "HEAD"] and
              (path == "/" or binary_part(path, 0, min(3, byte_size(path))) == "/t/") do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

    conn
    |> put_resp_header("location", "https://" <> canonical <> path <> query)
    |> send_resp(301, "")
    |> halt()
  end

  defp forward(conn, _canonical) do
    conn
    |> send_resp(404, "")
    |> halt()
  end
end
