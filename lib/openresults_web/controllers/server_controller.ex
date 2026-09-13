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

  ## `terms_url` when none is set

  With no `terms_url` saved in the panel or given in the environment, this
  server's own terms page (`OpenResultsWeb.TermsController`) is reported, at
  the endpoint's configured URL - `https://<host>/terms` in production - so
  the consent dialog links a real page with no configuration. A `terms_url`
  that is set still wins. Built from the endpoint's URL rather than the
  request's `Host` header, which a caller chooses.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.PublicPublishing

  def show(conn, _params) do
    info = Map.update!(PublicPublishing.server_info(), :terms_url, &(&1 || url(~p"/terms")))

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(info)
  end
end
