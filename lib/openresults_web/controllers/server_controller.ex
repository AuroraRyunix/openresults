defmodule OpenResultsWeb.ServerController do
  @moduledoc """
  `GET /api/server` - what this server is, and whether it takes installations.

  The first request an OpenPairings copy in public mode makes, and the one its
  consent dialog is built from: `operator` is the name the arbiter is asked to
  trust, `terms_url` what they are asked to read. Open, because it has to be
  answerable before the caller holds anything.

  `Cache-Control: no-store`, and on the API pipeline so the page cache never
  sees it: `public_registration` and `public_publishing` move when the
  operator flips a switch, and a copy that was true a minute ago is how an
  arbiter gets a consent dialog for a server that has just closed.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.PublicPublishing

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(PublicPublishing.server_info())
  end
end
