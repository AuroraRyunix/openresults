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
  # There are now two forms on this pipeline - the entry form and the report
  # form below - and they still need neither, for the reason set out where the
  # entry form is routed: they act on nobody's behalf, so there is no ambient
  # authority for a forged request to borrow. That reasoning is about THESE
  # forms. A form that ever acts for a visitor brings both plugs back with it.
  #
  # The language picker did not bring a session back either, and the argument
  # above is why: an explicit choice travels in the URL, and only a request
  # that carries one leaves a cookie behind. See `OpenResultsWeb.Locale`.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {OpenResultsWeb.Layouts, :root}
    # Ahead of everything that renders, and - because this pipeline runs
    # before the scope's own plugs - ahead of `Revalidate`, which cannot
    # build an ETag or find a cached page without knowing the language.
    plug OpenResultsWeb.Plugs.Locale
    plug :put_secure_browser_headers
    # Runs AFTER, because it rewrites the header the line above just set.
    # See `OpenResultsWeb.Framing` for why every page here is safe to embed
    # and why that is a property of the site rather than a list of routes.
    plug OpenResultsWeb.Framing
  end

  # The admin panel - the thing the comments above were waiting for: the
  # first page on this site that acts on somebody's behalf. So it gets the
  # session and CSRF protection the public pipeline argues it does not need,
  # and it gets them on its own pipeline, so none of it can leak onto a
  # public response. Nothing from `:browser` is shared: no locale (English
  # only), no framing permission (the opposite), no revalidation or page
  # cache (see `OpenResultsWeb.Plugs.AdminHeaders`).
  #
  # The order is load-bearing:
  #
  #   1. `AdminAuth` first, before anything has touched the response, so a
  #      request without a valid Cloudflare Access token leaves as the
  #      router's own unknown-route 404 - same status, body and headers.
  #   2. `AdminHeaders` next, so every admin response from here on, error
  #      pages included, is no-store and unframeable.
  #   3. The session and the CSRF check only after the gate, so a stranger
  #      is never handed a session cookie, not even a refused one.
  pipeline :admin do
    plug OpenResultsWeb.Plugs.AdminAuth
    plug OpenResultsWeb.Plugs.AdminHeaders
    # Always HTML, whatever `Accept` says - negotiating would only add a 406
    # nobody needs.
    plug :put_format, "html"
    plug OpenResultsWeb.Plugs.AdminSession
    plug :put_root_layout, html: {OpenResultsWeb.Admin.Layouts, :root}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :ingest do
    plug OpenResultsWeb.Plugs.IngestAuth
  end

  # The routes that exist only when `OPENRESULTS_PUBLIC_PUBLISHING=enabled` -
  # see `OpenResultsWeb.Plugs.PublicPublishingGate`. Put FIRST in a scope's
  # `pipe_through`, so a gated route answers exactly like an unrouted one.
  pipeline :public_publishing do
    plug OpenResultsWeb.Plugs.PublicPublishingGate
  end

  # The public pages. A tournament is addressed by its slug and a player by
  # `no`, the tournament pairing number - the same two handles the payload
  # uses, so no database id appears in a URL either.
  # The read pages get their own scope so they can carry the
  # revalidation plug, which the entry form below deliberately must not: a
  # form is not a document, and a browser deciding it already has the answer
  # is exactly wrong there.
  #
  # `Visibility` runs before `Revalidate` on every route that has a slug, in
  # both scopes: a hidden tournament must not get a 304 or a cached page, and a
  # pending one must carry `noindex` on every response, cached or not. See
  # `OpenResults.Tournaments` for what each status shows to whom.
  scope "/", OpenResultsWeb do
    pipe_through [:browser, OpenResultsWeb.Plugs.Visibility, OpenResultsWeb.Plugs.Revalidate]

    get "/t/:slug", TournamentController, :standings
    # The grid. In this scope and not the one below, because it is the
    # heaviest document this app renders - a row per player, a column per
    # round - and it is exactly the kind of page a hall full of phones asks
    # for repeatedly between two publishes. A read page that misses this plug
    # is not cached and nothing says so.
    get "/t/:slug/crosstable", TournamentController, :crosstable
    get "/t/:slug/round/:n", TournamentController, :round
    get "/t/:slug/player/:no", TournamentController, :player
  end

  scope "/", OpenResultsWeb do
    # `Visibility` does nothing on the three routes here without a slug.
    pipe_through [:browser, OpenResultsWeb.Plugs.Visibility]

    get "/", TournamentController, :index

    # One player, across every tournament published here - see
    # `OpenResultsWeb.PlayerHistory` for why this is keyed by FIDE id and not
    # by name. Not in the scope above: there is no single tournament, and so
    # no slug, for `Revalidate` to key an ETag against.
    get "/players/:fide_id", PlayerHistoryController, :show

    # What changed here, release by release - see
    # `OpenResultsWeb.ChangelogController` for why this sits beside
    # `players/:fide_id` rather than in the scope above: there is no
    # tournament and no slug behind it either, and nothing it shows can
    # change between two requests against the same running build.
    get "/changelog", ChangelogController, :show

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

    # Reporting a page to the operator - fake results, personal data, spam.
    # The same reasoning as the entry form above for having neither a session
    # nor a CSRF token: it acts on nobody's behalf, and a stranger with `curl`
    # can already do anything a forged request could. Guarded the same way,
    # too: only for a tournament the public can see, and rate-limited by
    # address. See `OpenResultsWeb.ReportController`.
    get "/t/:slug/report", ReportController, :new
    post "/t/:slug/report", ReportController, :create
  end

  # Public publishing, the open half: an OpenPairings installation asking for
  # its own key. No token - the key is what it is asking for - so it is
  # guarded instead by the environment gate, the `registration_open` switch,
  # address blocks and two registration budgets. See
  # `OpenResultsWeb.InstallationController` and `docs/public-publishing.md`.
  scope "/api", OpenResultsWeb do
    pipe_through [:public_publishing, :api]

    post "/installations", InstallationController, :create
  end

  # Writes. Everything behind this pipeline can create a tournament page, so
  # the token gate is on the pipeline rather than on the action - a route added
  # here later is authenticated by default rather than by remembering.
  #
  # That now has two halves. The OPERATOR token is accepted on every route
  # here, as it always was. An INSTALLATION key is accepted on none of them
  # unless the route names what it does in `installation_access`, and naming
  # it is what makes `OpenResultsWeb.InstallationAccess` run that action's
  # checks - ownership included - before the controller. A route added here
  # without it refuses installation keys with the anonymous 401, which
  # `test/openresults_web/default_deny_test.exs` walks this router to prove.
  scope "/api", OpenResultsWeb do
    pipe_through [:public_publishing, :api, :ingest]

    # Minting a slug for the installation asking. Gated like the route above;
    # the operator token is refused in the controller with
    # `installation_key_required`, since there is no installation to bind to.
    post "/tournaments", MintController, :create, private: %{installation_access: :mint}
  end

  scope "/api", OpenResultsWeb do
    pipe_through [:api, :ingest]

    post "/snapshots", SnapshotController, :create, private: %{installation_access: :publish}

    # History is a WRITE-side privilege, not a read-side one. An earlier
    # snapshot can hold a round or board the arbiter has since retracted, so
    # walking back through the append-only table is exactly as sensitive as
    # publishing into it.
    get "/tournaments/:slug/history", SnapshotController, :history,
      private: %{installation_access: :history}

    # Takedown. On the write pipeline because it is a write - the most
    # destructive one here - and gated a second time by the tournament key,
    # like publishing.
    #
    # It removes every snapshot, the whole history, and the registration queue
    # with the email addresses in it. Until this route existed the only way to
    # remove a published tournament was to SSH in and edit SQLite, which meant
    # that in practice a tournament published by accident stayed published.
    delete "/tournaments/:slug", SnapshotController, :delete,
      private: %{installation_access: :delete}

    # The arbiter pulling what the public form collected. Token-gated for the
    # same reason as history and for one of its own: this is the only route
    # in the system that returns an email address.
    get "/tournaments/:slug/registrations", RegistrationController, :index,
      private: %{installation_access: :registrations}
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

    # What this server is and whether it takes installations - the first thing
    # an OpenPairings copy in public mode asks. Open, and never cached: see
    # `OpenResultsWeb.ServerController`.
    get "/server", ServerController, :show

    # Reachable for a pending tournament and not for a hidden one, which gets
    # the same 404 as a slug that never published - see
    # `SnapshotController.show/2`.
    get "/tournaments/:slug", SnapshotController, :show
  end

  # The admin panel. Behind Cloudflare Access at the edge and checked again
  # by `:admin` - see `OpenResultsWeb.Plugs.AdminAuth` and docs/admin.md.
  #
  # Only routes that exist are linked from the panel's navigation
  # (`OpenResultsWeb.Admin.Layouts.nav_items/1`), so a section appears there
  # the moment its route is added here. An `/admin/...` path with no route
  # is the router's ordinary 404, for admins and strangers alike.
  scope "/admin", OpenResultsWeb.Admin do
    pipe_through :admin

    get "/", DashboardController, :show

    # Test-only: a harmless confirmation page and the POST behind it, so the
    # confirmation pattern and the CSRF check are proven through this exact
    # pipeline. Compiled in only where config/test.exs asks for it; no
    # production route table has it.
    if Application.compile_env(:openresults, :admin_confirmation_probe, false) do
      get "/confirmation-probe", ConfirmationProbeController, :new
      post "/confirmation-probe", ConfirmationProbeController, :create
    end
  end
end
