defmodule OpenResultsWeb.AdminAuthTest do
  @moduledoc """
  The `/admin` gate, end to end through the router.

  Two answers matter more than the rest. A request that did not come through
  this site's Access application gets the site's ordinary unknown-route 404 -
  not a page that looks like one, the same response - so nothing about it
  says a panel exists. And someone who did pass Access but is not on this
  server's list gets a plain 403, because they already know.
  """
  use OpenResultsWeb.ConnCase, async: false

  # Every refusal of a configured gate is logged for the operator. Asserted
  # where it matters, and kept out of the suite's output everywhere else.
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResultsWeb.AdminAccess.Config

  setup do
    reset_admin_access()
    configure_access()
    :ok
  end

  # A response reduced to what a client could compare: the request id is
  # per-request by design and says nothing about the route.
  defp observable({status, headers, body}) do
    {status, headers |> Enum.reject(fn {name, _} -> name == "x-request-id" end) |> Enum.sort(),
     body}
  end

  defp observable(%Plug.Conn{} = conn),
    do: observable({conn.status, conn.resp_headers, conn.resp_body})

  defp unknown_route(headers \\ []) do
    headers
    |> Enum.reduce(build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> get("/no-such-page-anywhere")
    |> observable()
  end

  defp admin(headers) do
    headers
    |> Enum.reduce(build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> get(~p"/admin")
  end

  describe "a valid token for a listed admin" do
    test "opens the dashboard, signed in as that email", %{conn: conn} do
      html = conn |> with_access_token() |> get(~p"/admin") |> html_response(200)

      assert html =~ "Signed in as <strong>arbiter@example.org</strong>"
    end

    test "matches the list case-insensitively, with the list's spacing trimmed", %{conn: conn} do
      Application.put_env(
        :openresults,
        :admin_emails,
        "  someone@example.org ,  ARBITER@Example.org  "
      )

      assert conn
             |> with_access_token("Arbiter@EXAMPLE.org")
             |> get(~p"/admin")
             |> html_response(200)
    end

    test "accepts the team domain configured with a scheme and a trailing slash", %{conn: conn} do
      Application.put_env(
        :openresults,
        :admin_access_team_domain,
        "https://OpenResults-Test.cloudflareaccess.com/"
      )

      assert conn |> with_access_token() |> get(~p"/admin") |> html_response(200)
      assert_received {:jwks_fetched, "openresults-test.cloudflareaccess.com"}
    end

    test "assigns the admin in the shape the moderation context takes as its actor", %{conn: conn} do
      conn = conn |> with_access_token() |> get(~p"/admin")

      assert conn.assigns.admin == %{email: "arbiter@example.org"}
    end
  end

  describe "unconfigured: every /admin path is an unknown route" do
    for key <- [:admin_access_team_domain, :admin_access_aud, :admin_emails] do
      test "with #{key} unset" do
        Application.delete_env(:openresults, unquote(key))
        response = [{"cf-access-jwt-assertion", token()}] |> admin() |> observable()

        assert {404, _, _} = response
        assert response == unknown_route()
      end

      test "with #{key} set but blank" do
        Application.put_env(:openresults, unquote(key), "  ")

        assert [{"cf-access-jwt-assertion", token()}] |> admin() |> observable() ==
                 unknown_route()
      end
    end

    test "with a team domain that is not a host name" do
      for junk <- ["https://", "team domain", "evil.example/x?y=", "localhost", "https://a..b"] do
        Application.put_env(:openresults, :admin_access_team_domain, junk)

        assert [{"cf-access-jwt-assertion", token()}] |> admin() |> observable() ==
                 unknown_route(),
               junk
      end

      refute_received {:jwks_fetched, _}
    end

    test "with an email list that holds no email" do
      Application.put_env(:openresults, :admin_emails, " , ,")

      assert [{"cf-access-jwt-assertion", token()}] |> admin() |> observable() == unknown_route()
    end

    test "including an unknown path under /admin and a POST" do
      Application.delete_env(:openresults, :admin_emails)

      assert build_conn() |> get("/admin/nothing-here") |> observable() == unknown_route()
      assert build_conn() |> post("/admin") |> observable() |> elem(0) == 404
    end

    test "and it asks Cloudflare for nothing" do
      Application.delete_env(:openresults, :admin_access_aud)
      admin([{"cf-access-jwt-assertion", token()}])

      refute_received {:jwks_fetched, _}
    end
  end

  describe "configured, but the request did not come through Access" do
    test "no header is exactly an unknown route" do
      assert admin([]) |> observable() == unknown_route()
    end

    test "an empty header is exactly an unknown route" do
      assert admin([{"cf-access-jwt-assertion", ""}]) |> observable() == unknown_route()
    end

    test "including when the client asks for JSON" do
      # The gate runs before the pipeline decides on a format, so even the
      # content negotiation of the 404 is the unknown route's own.
      accept = [{"accept", "application/json"}]
      assert admin(accept) |> observable() == unknown_route(accept)
    end

    test "every flavour of bad token is exactly an unknown route" do
      now = System.os_time(:second)

      tokens = %{
        wrong_aud: sign(claims(%{"aud" => ["another-application"]})),
        wrong_iss: sign(claims(%{"iss" => "https://another-team.cloudflareaccess.com"})),
        expired: sign(claims(%{"exp" => now - 600, "iat" => now - 4000, "nbf" => now - 4000})),
        not_yet: sign(claims(%{"nbf" => now + 600})),
        unknown_kid: sign(claims(), header: %{"kid" => "kid-nobody-has"}),
        other_key: sign(claims(), key_pair: key_pair(:intruder)),
        garbage: "this.is.not-a-token"
      }

      for {name, token} <- tokens do
        assert admin([{"cf-access-jwt-assertion", token}]) |> observable() == unknown_route(),
               "#{name} did not look like an unknown route"
      end
    end

    test "alg: none, and HS256 keyed with the public key, are unknown routes too" do
      {_private, public} = key_pair()
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, public)])
      payload = b64(Jason.encode!(claims()))

      none = b64(Jason.encode!(%{"alg" => "none", "kid" => "kid-1"})) <> "." <> payload <> "."

      hs_header = b64(Jason.encode!(%{"alg" => "HS256", "kid" => "kid-1"}))

      hs =
        hs_header <>
          "." <>
          payload <> "." <> b64(:crypto.mac(:hmac, :sha256, pem, hs_header <> "." <> payload))

      for token <- [none, hs] do
        assert admin([{"cf-access-jwt-assertion", token}]) |> observable() == unknown_route()
      end

      # Refused on the algorithm alone, so the key cache was never consulted.
      refute_received {:jwks_fetched, _}
    end

    test "a tampered payload is an unknown route" do
      [header, _payload, signature] = token() |> String.split(".")

      promoted =
        b64(Jason.encode!(claims(%{"email" => "arbiter@example.org", "exp" => 9_999_999_999})))

      assert admin([{"cf-access-jwt-assertion", Enum.join([header, promoted, signature], ".")}])
             |> observable() == unknown_route()
    end

    test "an unknown kid refetches once, then is an unknown route" do
      Application.put_env(:openresults, :admin_access_refetch_interval_ms, 0)

      # Warm the cache with the real key first.
      assert build_conn() |> with_access_token() |> get(~p"/admin") |> html_response(200)
      assert_received {:jwks_fetched, _}

      token = sign(claims(), header: %{"kid" => "kid-rotated-in-future"})
      assert admin([{"cf-access-jwt-assertion", token}]) |> observable() == unknown_route()

      assert_received {:jwks_fetched, _}
      refute_received {:jwks_fetched, _}
    end

    test "and the reason is logged for the operator, without the token" do
      token = sign(claims(%{"aud" => ["another-application"]}))

      log = capture_log(fn -> admin([{"cf-access-jwt-assertion", token}]) end)

      assert log =~ "admin panel: refused GET /admin (wrong_audience)"
      refute log =~ token
    end
  end

  describe "a valid token whose email is not on the list" do
    test "is a plain 403 that names the email and no configuration", %{conn: conn} do
      log =
        capture_log(fn ->
          conn = conn |> with_access_token("visitor@example.org") |> get(~p"/admin")

          assert conn.status == 403
          assert response_content_type(conn, :text) =~ "text/plain"
          assert conn.resp_body =~ "Signed in as visitor@example.org"
          refute conn.resp_body =~ "OPENRESULTS"
          refute conn.resp_body =~ "arbiter@example.org"

          # Still an admin response: never stored, never framed.
          assert get_resp_header(conn, "cache-control") == ["no-store"]
          assert get_resp_header(conn, "x-frame-options") == ["DENY"]
          # And no session was handed out on the way.
          assert get_resp_header(conn, "set-cookie") == []
        end)

      assert log =~ "visitor@example.org"
    end

    test "including a token with no email at all, as a service token has", %{conn: conn} do
      token = sign(claims() |> Map.delete("email") |> Map.put("common_name", "client-id.access"))

      capture_log(fn ->
        assert conn
               |> put_req_header("cf-access-jwt-assertion", token)
               |> get(~p"/admin")
               |> response(403)
      end)
    end
  end

  describe "the development bypass" do
    test "signs in as its configured email without any token", %{conn: conn} do
      Application.put_env(:openresults, :admin_dev_bypass, email: "dev@localhost")

      html = conn |> get(~p"/admin") |> html_response(200)

      assert html =~ "Signed in as <strong>dev@localhost</strong>"
      assert html =~ "Development bypass"
      # There is no Access in front of a laptop, so no sign-out link that
      # would lead nowhere.
      refute html =~ "/cdn-cgi/access/logout"
    end

    test "is ignored outside dev and test even when configured", %{conn: conn} do
      Application.put_env(:openresults, :admin_dev_bypass, email: "dev@localhost")
      Application.put_env(:openresults, :environment, :prod)
      on_exit(fn -> Application.put_env(:openresults, :environment, :test) end)

      assert conn |> get(~p"/admin") |> observable() == unknown_route()
    end

    test "a production boot with it configured refuses to start" do
      Application.put_env(:openresults, :admin_dev_bypass, email: "dev@localhost")
      Application.put_env(:openresults, :environment, :prod)
      on_exit(fn -> Application.put_env(:openresults, :environment, :test) end)

      # The application's real start callback. The guard is its first line,
      # so it raises before a single child is started.
      error =
        assert_raise RuntimeError, fn ->
          OpenResults.Application.start(:normal, [])
        end

      assert error.message =~ "refusing to start"
      assert error.message =~ ":admin_dev_bypass"
      assert error.message =~ ":prod"
    end

    test "the guard fails closed when the environment is not configured at all" do
      Application.put_env(:openresults, :admin_dev_bypass, email: "dev@localhost")
      Application.delete_env(:openresults, :environment)
      on_exit(fn -> Application.put_env(:openresults, :environment, :test) end)

      assert_raise RuntimeError, ~r/refusing to start/, fn -> Config.check_boot!() end
      assert Config.dev_bypass() == :off
    end

    test "and lets dev and test boot, and any environment without the bypass" do
      assert Config.check_boot!(:dev, email: "dev@localhost") == :ok
      assert Config.check_boot!(:test, email: "dev@localhost") == :ok
      assert Config.check_boot!(:prod, nil) == :ok
      assert Config.check_boot!(:prod, false) == :ok
    end
  end
end
