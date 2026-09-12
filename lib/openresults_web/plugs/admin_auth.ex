defmodule OpenResultsWeb.Plugs.AdminAuth do
  @moduledoc """
  The `/admin` gate: a Cloudflare Access token, verified here as well.

  ## Why verify what Cloudflare already checked

  Access sits in front of `/admin*` and will not let a request through
  without a sign-in that passed its policy. But an Access policy is a form
  in a dashboard, and a form can be edited wrong: a path typed as `admin/*`
  (which does not cover `/admin` itself), a policy widened while testing and
  never narrowed, an application deleted. If this app trusted "the request
  reached me", any of those would be an open admin panel. So the app checks
  the token Cloudflare attaches, against keys fetched from Cloudflare, for
  this application's audience, and then checks the email against its own
  list. A mistake on either side alone opens nothing.

  ## Who gets what

  | Situation | Answer |
  |---|---|
  | any of the three variables unset | 404, exactly an unknown route |
  | no `Cf-Access-Jwt-Assertion` header | 404, exactly an unknown route |
  | token malformed, wrong algorithm, unknown key, bad signature, wrong `aud` or `iss`, expired, not yet valid | 404, exactly an unknown route |
  | valid token, email not in `OPENRESULTS_ADMIN_EMAILS` | 403, plain text |
  | valid token, allowed email | through, with `assigns.admin = %{email: ...}` |

  **The 404s are the panel not being there.** A request with no valid token
  did not come through this site's Access application, so nothing about it
  deserves to learn that a panel exists. The 404 is not an imitation of the
  unknown-route page: this plug runs first in the pipeline and raises the
  router's own `Phoenix.Router.NoRouteError` with the connection untouched,
  so the endpoint renders the one and only not-found response the site has.
  Status, body and headers are the same bytes a mistyped URL gets.

  **The 403 is somebody who did pass Access** - they are in the Keycloak
  group, Cloudflare signed a token for this very application - but whom this
  server was not told about. The panel's existence is no secret to them, and
  "you are signed in but not on the list" is the one message that lets them,
  or the operator, fix it. It names the email the token carried, because a
  mismatch between the Keycloak address and the listed one is the likeliest
  reason, and it names no configuration.

  Every refusal of a configured gate is logged with its reason; the token
  itself never is.

  ## The development bypass

  With `config :openresults, :admin_dev_bypass, email: "..."` in dev or test
  configuration, the token check is skipped and that email is the admin. See
  `OpenResultsWeb.AdminAccess.Config` for the two locks that keep it out of
  production.
  """

  import Plug.Conn

  require Logger

  alias OpenResultsWeb.AdminAccess.{Config, JWT, KeyCache}
  alias OpenResultsWeb.Plugs.AdminHeaders

  @header "cf-access-jwt-assertion"

  def init(opts), do: opts

  def call(conn, _opts) do
    case Config.dev_bypass() do
      {:ok, email} -> admit(conn, email, :dev_bypass)
      :off -> gate(conn, Config.fetch())
    end
  end

  defp gate(conn, :unconfigured), do: not_found(conn)

  defp gate(conn, {:ok, config}) do
    with {:ok, token} <- token(conn),
         {:ok, claims} <-
           JWT.verify(token,
             key_for: &KeyCache.key(config.team_domain, &1),
             issuer: config.issuer,
             audience: config.audience
           ) do
      email = claims["email"]

      if Config.allowed?(config, email) do
        admit(conn, email, :cloudflare_access)
      else
        forbidden(conn, email)
      end
    else
      {:error, reason} ->
        Logger.warning(
          "admin panel: refused #{conn.method} #{conn.request_path} (#{reason}), answering 404"
        )

        not_found(conn)
    end
  end

  defp token(conn) do
    case get_req_header(conn, @header) do
      [token] when token != "" -> {:ok, token}
      [] -> {:error, :no_access_token}
      _empty_or_repeated -> {:error, :malformed}
    end
  end

  defp admit(conn, email, via) do
    conn
    # The shape `OpenResults.Moderation` takes as its `actor`, so a page can
    # hand this straight to the context.
    |> assign(:admin, %{email: email})
    |> assign(:admin_via, via)
  end

  # Raised with the connection exactly as the router handed it over. The
  # endpoint's error renderer uses the connection inside a NoRouteError, and
  # nothing has been put on this one yet, so what goes out is the site's
  # ordinary unknown-route 404 and not a page that merely resembles it.
  defp not_found(conn) do
    raise Phoenix.Router.NoRouteError, conn: conn, router: conn.private[:phoenix_router]
  end

  defp forbidden(conn, email) do
    shown = if is_binary(email), do: email, else: "(no email)"

    Logger.warning(
      "admin panel: #{inspect(shown)} passed Cloudflare Access but is not in OPENRESULTS_ADMIN_EMAILS, answering 403"
    )

    conn
    |> AdminHeaders.put()
    |> put_resp_content_type("text/plain")
    |> send_resp(
      403,
      "Forbidden\n\nSigned in as #{shown}, which is not on this server's list of administrators.\n"
    )
    |> halt()
  end
end
