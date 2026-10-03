defmodule OpenResultsWeb.UiFixesTest do
  @moduledoc """
  Five things a user hit on the hall screens and the team pages:

    1. the colour and full-screen controls sit in the BOTTOM-RIGHT corner,
       not over the clock;
    2. the full-screen button works (it never reached its handler: the
       controls' root carried `data-choice`, so `closest("[data-choice]")`
       from the button found the root and took the click for a colour pick);
    3. the projector and hall link cards come at the BOTTOM of the page;
    4. a team is shown by its full name everywhere, not its short name;
    5. a team event that publishes its first round reaches the readers: the
       page cache and ETag move with the snapshot, and the hall screen is
       pushed the change.
  """
  use OpenResultsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.Hall
  alias OpenResultsWeb.Plugs.Revalidate.Page
  alias OpenResultsWeb.Tournament

  @slug "team-swiss-fixture"

  setup do
    Snapshots.clear_cache()
    Page.clear()

    on_exit(fn ->
      Snapshots.clear_cache()
      Page.clear()
    end)

    :ok
  end

  defp count(html, selector) do
    html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp css do
    File.read!(Path.expand("../../assets/css/app.css", __DIR__)) |> String.replace("\r\n", "\n")
  end

  # The declarations of the first rule whose selector is exactly `selector`.
  defp rule(selector) do
    [_, body] = Regex.run(~r/^#{Regex.escape(selector)} \{\n(.*?)\n\}/ms, css())
    body
  end

  describe "1. the controls are in the bottom-right corner" do
    test "the stylesheet pins them to the bottom and right, never the top" do
      body = rule(".screen-tools")

      assert body =~ ~r/^\s*bottom: /m
      assert body =~ ~r/^\s*right: /m
      refute body =~ ~r/^\s*top: /m
    end

    test "the hall's footer leaves room for them on a wide screen" do
      assert css() =~
               ~r/@media screen and \(min-width: 900px\) and \(min-aspect-ratio: 1\/1\) \{\s*\.hall-foot \{\s*padding-right:/
    end
  end

  describe "2. the full-screen button" do
    for path <- ["hall", "projector"] do
      test "/#{path}: only the three colour buttons are colour choices", %{conn: conn} do
        {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss())
        {:ok, view, html} = live(conn, "/t/#{@slug}/#{unquote(path)}")

        # The root must not carry `data-choice`: the hook looked a clicked
        # element's `closest("[data-choice]")` up, found the root from the
        # full-screen button and never reached the full-screen branch.
        assert count(html, "#screen-tools[data-choice]") == 0
        assert count(html, "#screen-tools[data-initial-choice=black]") == 1
        assert count(html, "#screen-tools button[data-choice]") == 3
        assert count(html, "#fullscreen-toggle[data-choice]") == 0
        refute has_element?(view, "#fullscreen-toggle[data-choice]")
      end
    end

    test "the hook asks `button[data-choice]`, and the F key and the button share one path" do
      source =
        Path.expand("../../lib/openresults_web/live/hall_live.ex", __DIR__) |> File.read!()

      assert source =~ ~s[closest("button[data-choice]")]
      refute source =~ ~s[closest("[data-choice]")]
      assert source =~ ~s[if (e.target.closest("#fullscreen-toggle")) this.toggleFullscreen()]
      assert source =~ "webkitRequestFullscreen"
      assert source =~ "webkitfullscreenchange"
    end

    test "the hall page loads the script bundle that carries the hook", %{conn: conn} do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss())
      html = conn |> get("/t/#{@slug}/projector") |> html_response(200)

      assert count(html, ~s(script[src*="/assets/js/app.js"])) == 1
      assert count(html, "#screen-tools[phx-hook='.ScreenTools'], #screen-tools[phx-hook]") == 1
    end
  end

  describe "3. the link cards are at the foot of the page" do
    test "after the content on standings, cross-table and round pages", %{conn: conn} do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss())

      for path <- ["/t/#{@slug}", "/t/#{@slug}/crosstable", "/t/#{@slug}/round/2"] do
        html = conn |> get(path) |> html_response(200)

        assert count(html, "#screens") == 1, path
        assert count(html, "header.masthead #screens") == 0, path

        {screens_at, _} = :binary.match(html, ~s(id="screens"))
        {table_at, _} = :binary.match(html, "<table")
        last_table_end = html |> :binary.matches("</table>") |> List.last() |> elem(0)

        assert screens_at > table_at, path
        assert screens_at > last_table_end, path
      end
    end

    test "the cards still link both screens, once each", %{conn: conn} do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss())
      html = conn |> get("/t/#{@slug}") |> html_response(200)

      assert count(html, "#screens #projector-link.screen-card") == 1
      assert count(html, "#screens #hall-display-link.screen-card") == 1
    end
  end

  describe "4. a team is shown by its full name" do
    test "team_label/1 prefers the name, falls back to the short name" do
      assert Tournament.team_label(%{"name" => "Koninklijke Schaakkring Eupen", "short_name" => "KSK Eupen"}) ==
               "Koninklijke Schaakkring Eupen"

      assert Tournament.team_label(%{"name" => nil, "short_name" => "KSK"}) == "KSK"
      assert Tournament.team_label(%{"short_name" => "KSK"}) == "KSK"
      assert Tournament.team_label(nil) == ""
    end

    defp with_short_names(payload) do
      update_in(payload, ["teams"], fn teams ->
        Enum.map(teams, fn team -> Map.put(team, "short_name", "T" <> to_string(team["no"])) end)
      end)
    end

    test "hall data, standings, matches, team pages and cross-tables use the name", %{conn: conn} do
      payload = with_short_names(SnapshotPayloads.team_swiss())
      {:ok, _} = Snapshots.ingest(payload)

      data = Hall.build(payload, Hall.settings(payload))
      assert [m1 | _] = data.matches
      assert {m1.team_a, m1.team_b} == {"Antwerp Knights", "Charleroi"}

      for path <- [
            "/t/#{@slug}",
            "/t/#{@slug}/teams",
            "/t/#{@slug}/round/1",
            "/t/#{@slug}/crosstable",
            "/t/#{@slug}/team/1"
          ] do
        html = conn |> get(path) |> html_response(200)
        assert html =~ "Antwerp Knights", path
        refute html =~ ~r/>\s*T[1-5]\s*</, path
      end

      {:ok, view, _html} = live(conn, "/t/#{@slug}/hall")
      text = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert text =~ "Antwerp Knights"
      refute text =~ ~r/\bT[1-5]\b/
    end
  end

  describe "5. publishing the first round of a team event reaches the readers" do
    defp round_one_published do
      payload = SnapshotPayloads.team_swiss()
      update_in(payload, ["rounds"], fn rounds -> Enum.filter(rounds, &(&1["number"] == 1)) end)
    end

    defp region_version(html) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#live-region")
      |> LazyHTML.attribute("data-version")
      |> List.first()
    end

    test "the ETag moves, an old ETag is answered 200, and the new page has the round",
         %{conn: conn} do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss_unpaired())

      before = conn |> get("/t/#{@slug}")
      assert html_response(before, 200)
      [old_etag] = Plug.Conn.get_resp_header(before, "etag")
      assert count(before.resp_body, ~s(a[href="/t/#{@slug}/round/1"])) == 0
      assert build_conn() |> get("/t/#{@slug}/round/1") |> response(404)

      {:ok, _} = Snapshots.ingest(round_one_published())

      revalidated =
        build_conn()
        |> Plug.Conn.put_req_header("if-none-match", old_etag)
        |> get("/t/#{@slug}")

      assert html_response(revalidated, 200)
      [new_etag] = Plug.Conn.get_resp_header(revalidated, "etag")
      refute new_etag == old_etag
      assert count(revalidated.resp_body, ~s(a[href="/t/#{@slug}/round/1"])) == 1

      # The same request the page's refresher sends every 20 seconds.
      polled =
        build_conn()
        |> Plug.Conn.put_req_header("x-openresults-refresh", "1")
        |> get("/t/#{@slug}")
        |> html_response(200)

      refute region_version(polled) == region_version(before.resp_body)

      for path <- ["/t/#{@slug}/round/1", "/t/#{@slug}/teams", "/t/#{@slug}/crosstable"] do
        assert build_conn() |> get(path) |> html_response(200), path
      end
    end

    test "the team pages' refresher is the same poll loop as every static page", %{conn: conn} do
      {:ok, _} = Snapshots.ingest(round_one_published())

      for path <- ["/t/#{@slug}", "/t/#{@slug}/teams", "/t/#{@slug}/round/1", "/t/#{@slug}/team/1"] do
        html = conn |> get(path) |> html_response(200)
        assert count(html, "#live-region[data-version]") == 1, path
        assert html =~ "x-openresults-refresh", path
      end
    end

    test "the hall screen is pushed the change and shows the matches", %{conn: conn} do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss_unpaired())
      {:ok, view, _html} = live(conn, "/t/#{@slug}/hall")

      refute has_element?(view, "table.hall-matches")

      {:ok, _} = Snapshots.ingest(round_one_published())

      # The broadcast is sent before `ingest/1` returns; this call is
      # answered after the view has handled it.
      assert render(view) =~ "Antwerp Knights"
      assert has_element?(view, "table.hall-matches")
    end

    test "so does the projector view", %{conn: conn} do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss_unpaired())
      {:ok, view, _html} = live(conn, "/t/#{@slug}/projector")

      refute has_element?(view, "table.hall-matches")
      {:ok, _} = Snapshots.ingest(round_one_published())

      assert render(view) =~ "Antwerp Knights"
      assert has_element?(view, "table.hall-matches")
    end
  end
end
