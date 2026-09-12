defmodule OpenResultsWeb.Plugs.PublicPublishingGate do
  @moduledoc """
  Makes the public-publishing routes not exist unless
  `OPENRESULTS_PUBLIC_PUBLISHING=enabled`.

  Not a 403 and not a 503: the same 404 a path nobody routed gets, by raising
  the very exception the router raises for one. A club's self-hosted copy
  that upgrades must look exactly like it did before, down to what a scanner
  probing `/api/installations` learns - which is that there is nothing there.

  First in its pipeline, ahead of `accepts`, so that nothing about the request
  (an `Accept` header the API would refuse, a missing token) can make a gated
  route answer differently from an unrouted one.
  """

  alias OpenResults.PublicPublishing

  def init(opts), do: opts

  def call(conn, _opts) do
    if PublicPublishing.enabled?() do
      conn
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: OpenResultsWeb.Router
    end
  end
end
