defmodule OpenResultsWeb.Router do
  use OpenResultsWeb, :router

  # The read path, stripped to what a public results page actually needs.
  #
  # Gone from the scaffold's version: `fetch_session`, `fetch_live_flash` and
  # `protect_from_forgery`. This app has no accounts and nothing on these
  # pages changes state, so a session would exist only to be created, and CSRF
  # protects a form submission that cannot happen here. Their absence is the
  # feature: every response leaves without a Set-Cookie, which is why these
  # pages need no consent banner and can be cached by anything in front of
  # them. Add either one back only alongside the thing that needs it.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {OpenResultsWeb.Layouts, :root}
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :ingest do
    plug OpenResultsWeb.Plugs.IngestAuth
  end

  # The public pages. A tournament is addressed by its slug and a player by
  # `no`, the tournament pairing number - the same two handles the payload
  # uses, so no database id appears in a URL either.
  scope "/", OpenResultsWeb do
    pipe_through :browser

    get "/", TournamentController, :index
    get "/t/:slug", TournamentController, :standings
    get "/t/:slug/round/:n", TournamentController, :round
    get "/t/:slug/player/:no", TournamentController, :player
  end

  # Writes. Everything behind this pipeline can create a tournament page, so
  # the token gate is on the pipeline rather than on the action - a route added
  # here later is authenticated by default rather than by remembering.
  scope "/api", OpenResultsWeb do
    pipe_through [:api, :ingest]

    post "/snapshots", SnapshotController, :create

    # History is a WRITE-side privilege, not a read-side one. An earlier
    # snapshot can hold a round or board the arbiter has since retracted, so
    # walking back through the append-only table is exactly as sensitive as
    # publishing into it.
    get "/tournaments/:slug/history", SnapshotController, :history
  end

  # Reads. Open, because the CURRENT snapshot only ever contains what an
  # arbiter chose to publish: an unpublished round and a hidden board were
  # withheld when the document was built and were never sent here.
  #
  # That guarantee is about the current document only. Earlier ones can hold
  # what has since been retracted, which is why history is above, behind the
  # token, and why `show` refuses `?at=` rather than ignoring it.
  scope "/api", OpenResultsWeb do
    pipe_through :api

    get "/tournaments/:slug", SnapshotController, :show
  end
end
