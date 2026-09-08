defmodule OpenResultsWeb.LocaleTest do
  @moduledoc """
  Which language a spectator gets, and what the page says about itself.

  The people reading these pages have no account and no settings screen, so
  the browser's `accept-language` is the only thing that can speak for them.
  Everything here is about that header being honoured, being overridable, and
  - the half that is a correctness problem rather than a feature - never
  reaching a reader who asked for something else.
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.Locale
  alias OpenResultsWeb.Plugs.Revalidate.Page

  # The footer, which is on every page in the site and whose three versions
  # share no substring. "Standings"/"Stand" would not do: one contains the
  # other, so a Dutch assertion would pass against an English page.
  @english "Results are theirs"
  @dutch "De uitslagen zijn van hen"
  @french "Les résultats sont les siens"

  setup do
    Snapshots.clear_cache()
    Page.clear()

    on_exit(fn ->
      Snapshots.clear_cache()
      Page.clear()
    end)

    swiss = SnapshotPayloads.swiss()
    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  defp asking(language) do
    build_conn() |> put_req_header("accept-language", language)
  end

  describe "what the browser asks for" do
    test "a Belgian browser asking for Dutch gets Dutch", %{slug: slug} do
      html = "nl-BE,nl;q=0.9,en;q=0.8" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ @dutch
      refute html =~ @english
    end

    test "a Walloon browser asking for French gets French", %{slug: slug} do
      html = "fr-BE,fr;q=0.9,en;q=0.8" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ @french
      refute html =~ @english
    end

    test "quality values decide, not the order the header happens to be in", %{slug: slug} do
      html = "en;q=0.2,fr;q=0.9" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ @french
    end

    test "a language we do not ship falls through to the next one we do", %{slug: slug} do
      html = "de-DE,de;q=0.9,nl;q=0.5" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ @dutch
    end

    test "no header at all is English", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ @english
    end

    # A header is attacker-controlled input on a page anyone can request.
    # There is no reading of it that justifies a 500.
    test "a malformed header is English, not a crash", %{slug: slug} do
      for junk <- [";;;", "q=", "nl;q=banana", ",,,", "*", String.duplicate("x", 5_000), "nl;;q"] do
        Page.clear()
        html = junk |> asking() |> get(~p"/t/#{slug}") |> html_response(200)
        assert html =~ @english or html =~ @dutch
      end
    end
  end

  describe "the explicit choice" do
    test "?lang= outranks the header", %{slug: slug} do
      html =
        "nl-BE,nl;q=0.9"
        |> asking()
        |> get(~p"/t/#{slug}?lang=fr")
        |> html_response(200)

      assert html =~ @french
    end

    test "and is remembered, so the next page keeps the language", %{slug: slug} do
      chosen = "nl" |> asking() |> get(~p"/t/#{slug}?lang=fr")

      # Bound first: a function call cannot appear in a match pattern.
      cookie = Locale.cookie()
      assert %{^cookie => %{value: "fr"}} = chosen.resp_cookies

      html =
        "nl"
        |> asking()
        |> put_req_cookie(Locale.cookie(), "fr")
        |> get(~p"/t/#{slug}")
        |> html_response(200)

      assert html =~ @french
    end

    # The property the router's whole pipeline is built around: no session,
    # so no Set-Cookie, so no consent banner. A language picker nobody used
    # must not cost that.
    test "a reader who never picks a language is never given a cookie", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}") |> Map.fetch!(:resp_cookies) == %{}
      assert "nl" |> asking() |> get(~p"/t/#{slug}") |> Map.fetch!(:resp_cookies) == %{}
    end

    test "a ?lang= we do not ship changes nothing and stores nothing", %{slug: slug} do
      answer = "nl" |> asking() |> get(~p"/t/#{slug}?lang=klingon")

      assert html_response(answer, 200) =~ @dutch
      assert answer.resp_cookies == %{}
    end

    test "the picker offers every language and marks the one you are reading", %{slug: slug} do
      html = "fr" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      for code <- Locale.codes(), do: assert(html =~ ~s|hreflang="#{code}"|)
      assert html =~ ~s|href="/t/#{slug}?lang=nl"|
      assert html =~ ~s|aria-current="true"|
    end

    test "the picker keeps the parameters the page already had", %{slug: slug} do
      html = build_conn() |> get(~p"/t/#{slug}/round/1?display=1") |> html_response(200)

      assert html =~ ~s|href="/t/#{slug}/round/1?display=1&amp;lang=fr"|
    end
  end

  describe "what the response says about itself" do
    test "the html element carries the language it rendered in", %{slug: slug} do
      # Matched on the attribute rather than the whole opening tag: Phoenix
      # adds its own `phx-r` to <html>, so `<html lang="nl">` is never a
      # literal substring of the response and asserting on it would fail
      # while the page was perfectly correct.
      assert "nl" |> asking() |> get(~p"/t/#{slug}") |> html_response(200) =~ ~s|lang="nl"|
      assert "fr" |> asking() |> get(~p"/t/#{slug}") |> html_response(200) =~ ~s|lang="fr"|
    end

    # Without this, any cache between us and the reader is entitled to hand
    # one language's page to somebody who asked for another - the same bug
    # the page cache had, one hop further out.
    test "the response varies on what it read", %{conn: conn, slug: slug} do
      answer = get(conn, ~p"/t/#{slug}")

      assert get_resp_header(answer, "vary") == ["accept-language, cookie"]
    end
  end

  describe "the pages themselves" do
    test "the standings render in Dutch", %{slug: slug} do
      html = "nl" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ "Stand"
      assert html =~ "na ronde"
    end

    test "a round renders in French", %{slug: slug} do
      html = "fr" |> asking() |> get(~p"/t/#{slug}/round/1") |> html_response(200)

      assert html =~ "Ronde 1"
      assert html =~ "Blancs"
      assert html =~ "Noirs"
    end

    test "a player card renders in Dutch", %{slug: slug} do
      html = "nl" |> asking() |> get(~p"/t/#{slug}/player/1") |> html_response(200)

      assert html =~ "Ronde per ronde"
      assert html =~ "Tegenstander"
    end

    test "the entry form renders in French", %{slug: slug} do
      html = "fr" |> asking() |> get(~p"/t/#{slug}/register") |> html_response(200)

      assert html =~ "Nom"
      assert html =~ "Envoyer à l"
    end

    test "a validation failure is answered in the reader's language", %{slug: slug} do
      html =
        "nl"
        |> asking()
        |> post(~p"/t/#{slug}/register", %{"registration" => %{"name" => "", "email" => ""}})
        |> html_response(422)

      assert html =~ "geef de naam op die u op de paringslijst wilt zien"
      assert html =~ "de arbiter heeft een adres nodig om u te bereiken"
    end

    test "a 404 is answered in the reader's language too", %{conn: conn} do
      html = conn |> put_req_header("accept-language", "fr") |> get(~p"/t/nope")

      assert html_response(html, 404) =~ "Introuvable"
    end
  end

  describe "resolving, on its own" do
    test "the parameter wins, then the cookie, then the header" do
      assert Locale.resolve("fr", "nl", "en") == "fr"
      assert Locale.resolve(nil, "nl", "en") == "nl"
      assert Locale.resolve(nil, nil, "fr-BE") == "fr"
      assert Locale.resolve(nil, nil, nil) == "en"
    end

    test "anything unshippable is ignored rather than obeyed" do
      assert Locale.resolve("klingon", nil, "nl") == "nl"
      assert Locale.resolve(nil, "klingon", "fr") == "fr"
      assert Locale.resolve(nil, nil, "de,es") == "en"
    end

    test "nothing about a header can raise" do
      for junk <- [nil, "", ";", "q=1", "nl;q=", ["nl"], %{}, 42, "nl;q=1;q=2"] do
        assert Locale.resolve(nil, nil, junk) in Locale.codes()
      end
    end
  end
end
