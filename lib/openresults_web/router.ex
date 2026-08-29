defmodule OpenResultsWeb.Router do
  use OpenResultsWeb, :router

  # The read path, stripped to what a public results page actually needs.
  #
  # Gone from the scaffold's version: `fetch_session`, `fetch_live_flash` and
  # `protect_from_forgery`. This app has no accounts, so a session would exist
  # only to be created. Their absence is the feature: every response leaves
  # without a Set-Cookie, which is why these pages need no consent banner and
  # can be cached by anything in front of them. Add either one back only
  # alongside the thing that needs it.
  #
  # There is now one form on this pipeline - the entry form below - and it
  # still needs neither, for the reason set out where it is routed: it acts on
  # nobody's behalf, so there is no ambient authority for a forged request to
  # borrow. That reasoning is about THIS form. A form that ever acts for a
  # visitor brings both plugs back with it.
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

    # Entry. Under the tournament, beside `round` and `player`, because an
    # entry is for one event and the slug is the only handle there is - and
    # because a tournament that has not published here then 404s from the same
    # lookup as everywhere else, rather than needing its own rule.
    #
    # Still on `:browser`, which means still no session and still no CSRF
    # token, and that is a decision rather than an oversight. CSRF exists to
    # stop another site making a VISITOR'S browser act with the visitor's
    # ambient authority. There is no authority here: no account, no session,
    # nothing this form can do that a stranger with `curl` cannot do more
    # easily. A token would therefore protect nothing, while the session it
    # has to be checked against would put a Set-Cookie on a site whose whole
    # read path is deliberately cookie-free. Revisit both the moment this form
    # can do something on somebody's behalf.
    #
    # What actually guards it: an entry is only accepted for a slug that has
    # already published, and the controller rate-limits by address.
    get "/t/:slug/register", RegistrationController, :new
    post "/t/:slug/register", RegistrationController, :create

    # The entry form's FIDE search, proxied so the arbiter's address and the
    # token stay off the page - see `OpenResults.FideLookup`. Returns an
    # empty list rather than an error whenever it cannot answer, because the
    # form works without it.
    get "/t/:slug/fide", RegistrationController, :fide
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

    # Takedown. On the write pipeline because it is a write - the most
    # destructive one here - and gated a second time by the tournament key,
    # like publishing.
    #
    # It removes every snapshot, the whole history, and the registration queue
    # with the email addresses in it. Until this route existed the only way to
    # remove a published tournament was to SSH in and edit SQLite, which meant
    # that in practice a tournament published by accident stayed published.
    delete "/tournaments/:slug", SnapshotController, :delete

    # The arbiter pulling what the public form collected. Token-gated for the
    # same reason as history and for one of its own: this is the only route
    # in the system that returns an email address.
    get "/tournaments/:slug/registrations", RegistrationController, :index
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
