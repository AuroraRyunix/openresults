defmodule OpenResultsWeb.PublicNoticeTest do
  @moduledoc """
  The operator's notice on every public page (the admin upgrade, 2026-09-13).

  The part that matters most is the cache: public pages are kept in ETS and
  revalidated with ETags, and a notice changes every page without changing
  any snapshot. So setting, changing, clearing and expiring a notice must
  each give a visitor holding the old page a 200 with the new one - never a
  304, and never a body rendered under another notice.
  """
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.ServerSettings
  alias OpenResults.Snapshots
  alias OpenResultsWeb.A11y

  @admin %{email: "notice-admin@example.org"}
  @fide_id 1_503_014

  setup do
    RateLimit.reset()
    slug = unique_slug("notice")
    {:ok, _} = Snapshots.ingest(payload(slug))
    {:ok, slug: slug}
  end

  defp set!(attrs) do
    {:ok, notice} =
      Moderation.set_public_notice(Map.merge(%{"level" => "info"}, attrs), @admin)

    notice
  end

  defp notices(conn) do
    conn.resp_body
    |> LazyHTML.from_document()
    |> LazyHTML.query("#public-notice")
  end

  defp notice_text(conn), do: conn |> notices() |> LazyHTML.text() |> String.trim()

  defp etag(conn), do: conn |> get_resp_header("etag") |> hd()

  defp revalidate(path, etag),
    do: build_conn() |> put_req_header("if-none-match", etag) |> get(path)

  describe "on the page" do
    test "on every public page, above the content, in the visitor's language", %{slug: slug} do
      set!(%{"en" => "Maintenance tonight", "nl" => "Onderhoud vanavond"})

      for path <- [
            "/",
            "/t/#{slug}",
            "/t/#{slug}/crosstable",
            "/t/#{slug}/round/1",
            "/t/#{slug}/player/1",
            "/t/#{slug}/register",
            "/t/#{slug}/report",
            "/players/#{@fide_id}",
            "/changelog",
            "/t/no-such-slug"
          ] do
        conn = get(build_conn(), path)
        assert notice_text(conn) == "Maintenance tonight", path

        nl = get(build_conn(), path <> "?lang=nl")
        assert notice_text(nl) == "Onderhoud vanavond", path
      end

      html = get(build_conn(), "/t/#{slug}").resp_body
      [before_main, _] = String.split(html, ~s(<main id="main"), parts: 2)
      assert before_main =~ ~s(id="public-notice")
    end

    test "falls back to English, and says the text is English", %{slug: slug} do
      set!(%{"en" => "Maintenance tonight", "nl" => "Onderhoud vanavond"})

      doc =
        build_conn()
        |> get("/t/#{slug}?lang=fr")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("#public-notice p[lang=en]") |> LazyHTML.text() =~
               "Maintenance"

      doc =
        build_conn()
        |> get("/t/#{slug}?lang=nl")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("#public-notice p[lang=nl]") |> Enum.count() == 1
    end

    test "is a named note, not a live region, and is translated", %{slug: slug} do
      set!(%{"en" => "Heads up", "level" => "warning"})

      for {lang, name} <- [{"en", "Notice"}, {"nl", "Mededeling"}, {"fr", "Avis"}] do
        doc =
          build_conn()
          |> get("/t/#{slug}?lang=#{lang}")
          |> html_response(200)
          |> LazyHTML.from_document()

        [note] = doc |> LazyHTML.query("#public-notice") |> Enum.to_list()
        assert LazyHTML.attribute(note, "role") == ["note"]
        assert LazyHTML.attribute(note, "aria-label") == [name]
        assert LazyHTML.attribute(note, "aria-live") == []
        assert LazyHTML.attribute(note, "class") == ["public-notice public-notice-warning"]
      end
    end

    test "is escaped, and HTML is refused before it is stored", %{slug: slug} do
      assert {:error, changeset} =
               Moderation.set_public_notice(
                 %{"en" => "<script>alert(1)</script>", "level" => "info"},
                 @admin
               )

      assert changeset.errors[:en]
      assert Moderation.public_notice() == nil

      set!(%{"en" => "Fish & chips \"tonight\""})
      html = get(build_conn(), "/t/#{slug}").resp_body
      assert html =~ "Fish &amp; chips &quot;tonight&quot;"
    end

    test "is not on the projector view, and not in the admin panel", %{slug: slug} do
      set!(%{"en" => "Maintenance tonight"})

      assert notices(get(build_conn(), "/t/#{slug}/round/1")) |> Enum.count() == 1
      assert notices(get(build_conn(), "/t/#{slug}/round/1?display=1")) |> Enum.count() == 0

      import OpenResultsWeb.AdminAccessHelpers
      reset_admin_access()
      configure_access()

      for path <- ["/admin", "/admin/tournaments", "/admin/settings"] do
        assert notices(admin_get(path)) |> Enum.count() == 0, path
      end

      # The settings page previews it instead, one per language.
      doc = admin_get("/admin/settings") |> html_response(200) |> LazyHTML.from_document()
      assert doc |> LazyHTML.query("#notice-preview-en") |> LazyHTML.text() =~ "Maintenance"
    end

    test "passes the accessibility audit on every kind of page, at both levels", %{slug: slug} do
      for level <- ["info", "warning"] do
        set!(%{"en" => "Maintenance tonight", "level" => level})

        for path <- ["/", "/t/#{slug}", "/t/#{slug}/register", "/players/#{@fide_id}"] do
          conn = get(build_conn(), path)
          violations = A11y.audit(conn.resp_body, lang: "en")
          assert violations == [], "#{level} #{path}\n#{A11y.explain(violations)}"
        end
      end
    end

    test "input the notice cannot take comes back as a changeset, never a crash" do
      now = DateTime.utc_now()

      for attrs <- [
            %{},
            %{"en" => "", "level" => "info"},
            %{"en" => String.duplicate("x", 301), "level" => "info"},
            %{"en" => "ok", "level" => "shout"},
            %{"en" => "ok", "level" => "info", "nl" => "a < b"},
            %{"en" => "ok", "level" => "info", "expires_at" => DateTime.to_iso8601(now)},
            %{"en" => "ok", "level" => "info", "expires_at" => "tomorrow"},
            %{"en" => %{"x" => 1}, "level" => "info"}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} =
                 Moderation.set_public_notice(attrs, @admin),
               inspect(attrs)
      end

      assert Moderation.public_notice() == nil
    end
  end

  describe "the page cache and the ETag" do
    test "a notice set after a page was cached: no 304, and not the cached body", %{slug: slug} do
      path = "/t/#{slug}"
      first = get(build_conn(), path)
      assert notices(first) |> Enum.count() == 0
      # Served from the page cache the second time.
      assert get(build_conn(), path).resp_body == first.resp_body
      assert revalidate(path, etag(first)).status == 304

      set!(%{"en" => "Now there is a notice"})

      conn = revalidate(path, etag(first))
      assert conn.status == 200
      refute etag(conn) == etag(first)
      assert notice_text(conn) == "Now there is a notice"
      assert notice_text(get(build_conn(), path)) == "Now there is a notice"
    end

    test "changing the notice: no 304 across the change, in every language", %{slug: slug} do
      set!(%{"en" => "First"})

      held =
        for lang <- ~w(en nl fr) do
          path = "/t/#{slug}?lang=#{lang}"
          conn = get(build_conn(), path)
          # Warm the page cache under the first notice.
          get(build_conn(), path)
          {path, etag(conn)}
        end

      set!(%{"en" => "Second"})

      for {path, tag} <- held do
        conn = revalidate(path, tag)
        assert conn.status == 200, "#{path} answered 304 across a notice change"
        assert notice_text(conn) == "Second", "#{path} served a body cached under the old notice"
      end
    end

    test "clearing the notice: no 304, and the notice is gone", %{slug: slug} do
      path = "/t/#{slug}/crosstable"
      set!(%{"en" => "Going away"})
      held = get(build_conn(), path)
      get(build_conn(), path)

      {:ok, _} = Moderation.clear_public_notice(@admin)

      conn = revalidate(path, etag(held))
      assert conn.status == 200
      assert notices(conn) |> Enum.count() == 0
      assert {:error, :not_set} = Moderation.clear_public_notice(@admin)
    end

    test "an expired notice disappears by itself: no 304, no cached body, no admin action", %{
      slug: slug
    } do
      path = "/t/#{slug}"

      # Written as the panel stores it, expiring a moment from now - the
      # panel's own form refuses an instant this close, to the second.
      now = DateTime.utc_now()

      document = %{
        "en" => "Short-lived",
        "level" => "info",
        "expires_at" => DateTime.to_iso8601(DateTime.add(now, 400, :millisecond)),
        "set_at" => DateTime.to_iso8601(now),
        "set_by" => @admin.email
      }

      ServerSettings.put(ServerSettings.notice_key(), Jason.encode!(document), @admin.email)
      ServerSettings.refresh()

      held = get(build_conn(), path)
      assert notice_text(held) == "Short-lived"
      assert revalidate(path, etag(held)).status == 304

      Process.sleep(500)

      conn = revalidate(path, etag(held))
      assert conn.status == 200
      assert notices(conn) |> Enum.count() == 0
      assert notices(get(build_conn(), "/")) |> Enum.count() == 0

      # Still stored, for the panel to show as expired, until it is cleared.
      assert %{en: "Short-lived"} = Moderation.public_notice()
    end

    test "the action log keeps every change, old and new", %{slug: _slug} do
      set!(%{"en" => "One"})
      set!(%{"en" => "Two", "fr" => "Deux", "level" => "warning"})
      {:ok, _} = Moderation.clear_public_notice(@admin)

      [clear, second, first] =
        Moderation.list_actions(%{target_type: "setting", target: "public_notice", limit: 3})

      assert %{actor: "notice-admin@example.org", action: "set_notice", details: %{"from" => nil}} =
               first

      assert %{"from" => %{"en" => "One"}, "to" => %{"en" => "Two", "fr" => "Deux"}} =
               second.details

      assert %{action: "clear_notice", details: %{"from" => %{"en" => "Two"}}} = clear
    end
  end
end
