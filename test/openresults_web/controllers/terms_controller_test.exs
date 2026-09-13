defmodule OpenResultsWeb.TermsControllerTest do
  @moduledoc """
  `GET /terms` - the terms, acceptable use and privacy page: its languages,
  the settings it shows, that a change to them is on the next request, the
  footer link to it, and the `terms_url` `GET /api/server` reports for it.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResultsWeb.A11y

  @admin %{email: "terms-admin@example.org"}

  setup do
    RateLimit.reset()
    put_env(:operator_name, nil)
    put_env(:contact_email, nil)
    put_env(:terms_url, nil)
    :ok
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:openresults, key)
    Application.put_env(:openresults, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:openresults, key, v)
        :error -> Application.delete_env(:openresults, key)
      end
    end)
  end

  defp terms(query \\ ""), do: build_conn() |> get("/terms" <> query) |> html_response(200)

  describe "the page" do
    test "renders in English, Dutch and French, and passes the accessibility audit in each" do
      for {lang, title, heading} <- [
            {"en", "Terms and privacy - OpenResults", "Having something removed or corrected"},
            {"nl", "Voorwaarden en privacy - OpenResults",
             "Iets laten verwijderen of verbeteren"},
            {"fr", "Conditions et confidentialité - OpenResults",
             "Faire retirer ou corriger quelque chose"}
          ] do
        html = terms("?lang=#{lang}")

        assert html =~ "<title>#{title}</title>", lang
        assert html =~ heading, lang

        violations = A11y.audit(html, lang: lang)
        assert violations == [], "/terms?lang=#{lang}\n#{A11y.explain(violations)}"
      end
    end

    test "has one h1 and every section the terms promise, with the last-updated date" do
      document = terms() |> LazyHTML.from_document()

      assert document |> LazyHTML.query("h1") |> Enum.count() == 1

      for id <- ~w(terms-operator terms-publishing terms-not-allowed terms-visibility
                   terms-moderation terms-removal terms-privacy terms-no-guarantee terms-changes) do
        assert document |> LazyHTML.query("section##{id}") |> Enum.count() == 1, id
      end

      assert document |> LazyHTML.query("#terms-updated") |> LazyHTML.text() =~
               Date.to_iso8601(OpenResultsWeb.TermsController.updated())
    end

    test "states the retention periods the server is running with, not fixed numbers" do
      put_env(:registration_retention_days, 45)
      put_env(:report_contact_retention_days, 120)
      put_env(:backup_retention, 14)

      html = terms()

      assert html =~ "Entries: deleted 45 days after the tournament ends"
      assert html =~ "deleted 120 days after the report is resolved"
      assert html =~ "gone from every backup within 14 days of being deleted"
      assert html =~ "The internet addresses of reports and installations: deleted after 30 days."
    end

    test "names the operator from the setting, and says so plainly when there is none" do
      assert terms() =~ "This site is run by the operator of this server."

      {:ok, _} = Moderation.put_server_setting(:operator_name, "ZeroTwo", @admin)

      html = terms()
      assert html =~ "This site is run by ZeroTwo."
      assert html =~ "ZeroTwo hosts it and handles reports and removal."
    end

    test "never renders an address when no contact email is set: the report route only" do
      html = terms()

      refute html =~ "mailto:"
      refute html =~ "terms-contact"
      refute html =~ "write to the operator"
      assert html =~ "use “Report this page” on the tournament concerned."
    end

    test "shows the contact email as a plain mailto link, fenced from Cloudflare's obfuscation" do
      put_env(:contact_email, "takedown@example.org")

      html = terms()
      document = LazyHTML.from_document(html)

      assert document |> LazyHTML.query("#terms-contact-email") |> LazyHTML.attribute("href") ==
               ["mailto:takedown@example.org"]

      # Cloudflare's markers reach the browser, around the link and nothing else.
      [_, fenced] = String.split(html, ~s(id="terms-contact"), parts: 2)
      [fenced, _] = String.split(fenced, "</p>", parts: 2)

      assert fenced =~
               ~r{<!--email_off-->\s*<a\b[^>]*\bhref="mailto:takedown@example.org"[^>]*>\s*takedown@example.org\s*</a>\s*<!--/email_off-->},
             fenced

      assert html =~ "or write to the operator at the address above."
    end

    test "is never cached: a contact email changed in the panel is on the next request" do
      assert build_conn() |> get("/terms") |> html_response(200) |> Kernel.=~("mailto:") == false

      {:ok, _} = Moderation.put_server_setting(:contact_email, "first@example.org", @admin)
      conn = get(build_conn(), "/terms")
      assert html_response(conn, 200) =~ "mailto:first@example.org"
      assert get_resp_header(conn, "etag") == []

      {:ok, _} = Moderation.put_server_setting(:contact_email, "second@example.org", @admin)
      html = build_conn() |> get("/terms") |> html_response(200)
      assert html =~ "mailto:second@example.org"
      refute html =~ "first@example.org"

      {:ok, _} = Moderation.reset_server_setting(:contact_email, @admin)
      refute build_conn() |> get("/terms") |> html_response(200) =~ "mailto:"
    end

    test "sets no cookie" do
      conn = get(build_conn(), "/terms")
      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  describe "the link to it" do
    setup do
      slug = unique_slug("terms")
      slug |> payload() |> publish(operator_token()) |> json_response(200)
      {:ok, slug: slug}
    end

    test "is in the footer of every public page", %{slug: slug} do
      for path <- [
            "/",
            "/t/#{slug}",
            "/t/#{slug}/crosstable",
            "/t/#{slug}/round/1",
            "/t/#{slug}/player/1",
            "/changelog",
            "/terms",
            "/t/#{slug}/register",
            "/t/#{slug}/report",
            "/t/no-such-tournament"
          ] do
        conn = get(build_conn(), path)
        document = conn.resp_body |> LazyHTML.from_document()

        assert document |> LazyHTML.query(~s(footer a.terms-link[href="/terms"])) |> Enum.count() ==
                 1,
               path
      end
    end

    test "is translated in the footer", %{slug: slug} do
      html = build_conn() |> get("/t/#{slug}?lang=nl") |> html_response(200)
      assert html =~ "Voorwaarden en privacy"

      html = build_conn() |> get("/t/#{slug}?lang=fr") |> html_response(200)
      assert html =~ "Conditions et confidentialité"
    end

    test "is not on the projector view", %{slug: slug} do
      html = build_conn() |> get("/t/#{slug}/round/1?display=1") |> html_response(200)
      refute html =~ ~s(href="/terms")
    end

    test "sits under the send button of the entry form and the report form", %{slug: slug} do
      for {path, id} <- [
            {"/t/#{slug}/register", "registration-terms"},
            {"/t/#{slug}/report", "report-terms"}
          ] do
        document = build_conn() |> get(path) |> html_response(200) |> LazyHTML.from_document()

        assert document |> LazyHTML.query(~s(form a##{id}[href="/terms"])) |> Enum.count() == 1,
               path
      end
    end
  end

  describe "GET /api/server" do
    test "reports this server's own /terms page when no terms_url is set" do
      body = build_conn() |> get("/api/server") |> json_response(200)
      assert body["terms_url"] == OpenResultsWeb.Endpoint.url() <> "/terms"
    end

    test "a terms_url set in the environment or the panel still wins" do
      put_env(:terms_url, "https://env.example/terms")

      assert build_conn() |> get("/api/server") |> json_response(200) |> Map.get("terms_url") ==
               "https://env.example/terms"

      {:ok, _} = Moderation.put_server_setting(:terms_url, "https://panel.example/terms", @admin)

      assert build_conn() |> get("/api/server") |> json_response(200) |> Map.get("terms_url") ==
               "https://panel.example/terms"

      {:ok, _} = Moderation.reset_server_setting(:terms_url, @admin)
      put_env(:terms_url, nil)

      assert build_conn() |> get("/api/server") |> json_response(200) |> Map.get("terms_url") ==
               OpenResultsWeb.Endpoint.url() <> "/terms"
    end
  end
end
