defmodule OpenResultsWeb.ChangelogControllerTest do
  @moduledoc """
  `GET /changelog` - and the footer link that brings a reader here from
  every other page.
  """
  use OpenResultsWeb.ConnCase

  test "renders CHANGELOG.md content under a top-level heading", %{conn: conn} do
    html = conn |> get(~p"/changelog") |> html_response(200)

    assert html =~ "Changelog</h1>"
    assert html =~ "changelog-body"
    # A real entry from CHANGELOG.md, not just an empty shell.
    assert html =~ "0.1."
  end

  test "it needs no tournament and no account", %{conn: conn} do
    # Same conn as any anonymous visitor gets - there is no session and
    # nothing to log into anywhere on this site.
    html = conn |> get(~p"/changelog") |> html_response(200)

    assert html =~ "changelog-body"
  end

  test "the footer's build stamp on another page links here", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(href="/changelog")
    assert html =~ "build-id"
  end

  test "the page's own chrome answers in the reader's language", %{conn: conn} do
    # The page's OWN heading, subtitle and title translate - CHANGELOG.md's
    # content does not, the same way OpenPairings' own `/changelog` leaves
    # its rendered markdown in English regardless of locale. That is the
    # page's own `# Changelog` landing as its own, separate, always-English
    # <h1> inside `.changelog-body` - so this checks the CHROME around it,
    # not the whole document.
    html =
      conn
      |> put_req_header("accept-language", "nl")
      |> get(~p"/changelog")
      |> html_response(200)

    assert html =~ "<title>Wijzigingen - OpenResults</title>"
    assert html =~ "Elke release van deze site, op volgorde."

    html =
      conn
      |> put_req_header("accept-language", "fr")
      |> get(~p"/changelog")
      |> html_response(200)

    assert html =~ "<title>Journal des modifications - OpenResults</title>"
    # Phoenix.HTML escapes the apostrophe on the way out.
    assert html =~ "Chaque version de ce site, dans l&#39;ordre."
  end
end
