defmodule OpenResultsWeb.AccessibilityTest do
  @moduledoc """
  Every page this site renders, held to the invariants in
  `OpenResultsWeb.A11y` - the decidable half of the accessibility pass of
  2026-09-13 (`docs/accessibility-2026-09-13.md`).

  The public pages are walked from the router rather than listed by hand, so
  a page added later is audited the day it is routed: a browser GET route
  with no entry in `pages/2` fails "every page is walked" and says which one.
  Each page is rendered in every state that changes its markup - before round
  1 and after, Keizer and swiss, the projector, a form sent back with its
  errors - because a label that only goes missing on the error render is the
  one nobody tests by hand.

  JavaScript does not run here, so what the scripts do with focus, with the
  live region and with the dialog is the manual checklist's job. What IS
  asserted is the markup those scripts depend on.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.PublicPublishingFixtures, only: [unique_slug: 1]
  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.{RateLimit, SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.{A11y, AdminWorld}

  # The one browser GET route that answers JSON, for the entry form's
  # script. Not a page.
  @not_pages ["/t/:slug/fide"]

  setup do
    RateLimit.reset()

    swiss = publish(SnapshotPayloads.swiss(), unique_slug("swiss"))
    keizer = publish(SnapshotPayloads.keizer(), unique_slug("keizer"))

    before_round_one =
      SnapshotPayloads.swiss()
      |> put_in(["standings", "rows"], [])
      |> publish(unique_slug("before"))

    closed =
      SnapshotPayloads.swiss()
      |> put_in(["tournament", "registration_open"], false)
      |> publish(unique_slug("closed"))

    team_rr = publish(SnapshotPayloads.team_round_robin(), unique_slug("team-rr"))
    team_swiss = publish(SnapshotPayloads.team_swiss(), unique_slug("team-swiss"))

    %{"fide_id" => fide_id} =
      Enum.find(SnapshotPayloads.swiss()["players"], & &1["fide_id"])

    team_no = SnapshotPayloads.team_round_robin()["teams"] |> hd() |> Map.get("no")

    {:ok,
     world: %{
       swiss: swiss,
       keizer: keizer,
       before_round_one: before_round_one,
       closed: closed,
       team_rr: team_rr,
       team_swiss: team_swiss,
       team_no: team_no,
       fide_id: fide_id
     }}
  end

  defp publish(payload, slug) do
    {:ok, _} = Snapshots.ingest(put_in(payload, ["tournament", "slug"], slug))
    slug
  end

  # Every concrete page behind one route, in each state that changes its
  # markup.
  defp pages(%{path: path}, world) do
    case path do
      "/" ->
        ["/", "/?lang=nl", "/?lang=fr"]

      "/t/:slug" ->
        for slug <- [
              world.swiss,
              world.keizer,
              world.before_round_one,
              world.team_rr,
              world.team_swiss
            ],
            lang <- ["en", "nl", "fr"],
            do: "/t/#{slug}?lang=#{lang}"

      "/t/:slug/crosstable" ->
        [
          "/t/#{world.swiss}/crosstable",
          "/t/#{world.keizer}/crosstable",
          "/t/#{world.before_round_one}/crosstable"
        ]

      "/t/:slug/round/:n" ->
        [
          "/t/#{world.swiss}/round/1",
          "/t/#{world.swiss}/round/5",
          "/t/#{world.swiss}/round/5?display=1",
          "/t/#{world.keizer}/round/1",
          "/t/#{world.swiss}/round/4",
          "/t/#{world.team_rr}/round/1",
          "/t/#{world.team_rr}/round/1?team=#{world.team_no}",
          "/t/#{world.team_swiss}/round/1"
        ]

      "/t/:slug/player/:no" ->
        [
          "/t/#{world.swiss}/player/1",
          "/t/#{world.keizer}/player/1",
          "/t/#{world.before_round_one}/player/1"
        ]

      "/t/:slug/team/:no" ->
        [
          "/t/#{world.team_rr}/team/#{world.team_no}",
          "/t/#{world.team_rr}/team/999"
        ]

      "/t/:slug/board-prizes" ->
        ["/t/#{world.team_rr}/board-prizes", "/t/#{world.team_swiss}/board-prizes"]

      "/players/:fide_id" ->
        ["/players/#{world.fide_id}", "/players/999999999"]

      "/changelog" ->
        ["/changelog"]

      "/terms" ->
        ["/terms", "/terms?lang=nl", "/terms?lang=fr"]

      "/t/:slug/register" ->
        [
          "/t/#{world.swiss}/register",
          "/t/#{world.swiss}/register?lang=fr",
          "/t/#{world.closed}/register",
          "/t/no-such-tournament/register"
        ]

      "/t/:slug/report" ->
        ["/t/#{world.swiss}/report", "/t/#{world.swiss}/report?lang=nl"]

      other ->
        flunk("#{other} is a browser page nobody walks - add it to pages/2")
    end
  end

  # `__routes__/0` does not say which pipeline a route runs through, so the
  # public pages are every GET that is neither the API nor the admin panel.
  defp browser_routes do
    for %{verb: :get, path: path} = route <- OpenResultsWeb.Router.__routes__(),
        not String.starts_with?(path, ["/api/", "/admin"]),
        path not in @not_pages,
        do: route
  end

  # The changelog's tables come from CHANGELOG.md, and markdown has no way to
  # write a caption. Their header cells are still scoped - see
  # `OpenResults.Markdown`.
  defp skips("/changelog" <> _), do: [:table_name]
  defp skips(_path), do: []

  defp locale_of(path) do
    case Regex.run(~r/[?&]lang=(\w+)/, path) do
      [_, lang] -> lang
      nil -> "en"
    end
  end

  defp assert_clean(html, path, opts \\ []) do
    violations = A11y.audit(html, Keyword.put_new(opts, :lang, locale_of(path)))
    assert violations == [], "#{path}\n#{A11y.explain(violations)}"
  end

  describe "every public page" do
    test "is walked, and passes the audit in every state", %{world: world} do
      with_fide_search(fn ->
        results =
          for route <- browser_routes(), path <- pages(route, world) do
            conn = get(build_conn(), path)
            assert conn.status in [200, 403, 404], "#{path} answered #{conn.status}"
            {path, A11y.audit(conn.resp_body, lang: locale_of(path), skip: skips(path))}
          end

        failures = for {path, violations} <- results, violations != [], do: {path, violations}

        assert failures == [],
               Enum.map_join(failures, "\n\n", fn {path, v} -> "#{path}\n#{A11y.explain(v)}" end)

        assert length(results) >= 30
      end)
    end

    test "the entry form, sent back with its errors, in every language", %{world: world} do
      for lang <- ["en", "nl", "fr"] do
        path = "/t/#{world.swiss}/register?lang=#{lang}"

        html =
          build_conn()
          |> post(path, registration: %{"name" => "x", "email" => "not an address"})
          |> html_response(422)

        assert_clean(html, path)
      end
    end

    test "the report form, sent back with its errors", %{world: world} do
      path = "/t/#{world.swiss}/report"
      html = build_conn() |> post(path, report: %{}) |> html_response(422)

      assert_clean(html, path)
    end

    test "the refusal a flood of entries gets", %{world: world} do
      conn =
        Enum.reduce_while(1..10, nil, fn _, _ ->
          conn =
            build_conn()
            |> put_req_header("cf-connecting-ip", "192.0.2.77")
            |> post("/t/#{world.swiss}/register", registration: %{})

          if conn.status == 429, do: {:halt, conn}, else: {:cont, conn}
        end)

      assert conn.status == 429
      assert_clean(conn.resp_body, "/t/#{world.swiss}/register")
    end
  end

  describe "the markup the page scripts rely on" do
    test "the announcer sits outside the region the refresher replaces", %{world: world} do
      document =
        build_conn() |> get("/t/#{world.swiss}") |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query("#announcer[aria-live=polite]") |> Enum.count() == 1
      assert document |> LazyHTML.query("#live-region #announcer") |> Enum.empty?()
    end

    test "the filter bar is a real GET form with labelled controls and a visible submit button",
         %{world: world} do
      document =
        build_conn() |> get("/t/#{world.swiss}") |> html_response(200) |> LazyHTML.from_document()

      forms = LazyHTML.query(document, "form[data-filter-form]")
      assert Enum.count(forms) == 1

      assert LazyHTML.query(document, ~s(form[data-filter-form][method="get"])) != []

      # A `<fieldset>`/`<legend>` grouping, the site's existing convention
      # for a form's own controls (see `registration_html.ex`), and every
      # control wrapped in its own `<label>` - so this works by keyboard and
      # is read sensibly by a screen reader with no `aria-*` wiring of its
      # own required.
      assert LazyHTML.query(document, "form[data-filter-form] fieldset > legend") != []
      selects = LazyHTML.query(document, "form[data-filter-form] label > select")
      inputs = LazyHTML.query(document, "form[data-filter-form] label > input")
      assert Enum.count(selects) + Enum.count(inputs) > 0

      # A real, visible submit button - not hidden behind `html.has-js`, so
      # the form works exactly the same with the script switched off.
      assert LazyHTML.query(document, ~s(form[data-filter-form] button[type="submit"])) != []

      # The middle controls collapse behind a real `<details>`/`<summary>` on
      # a narrow screen - no script required to open it.
      assert LazyHTML.query(document, "details.filter-disclosure > summary") != []
    end

    test "the filter chips are links with accessible names, not bare icons", %{world: world} do
      document =
        build_conn()
        |> get("/t/#{world.swiss}?category=A")
        |> html_response(200)
        |> LazyHTML.from_document()

      chips = LazyHTML.query(document, ".filter-chip a")
      assert chips != []

      for chip <- chips do
        # Either an `aria-label` or real text content names the chip - never
        # only the aria-hidden "✕".
        aria = chip |> LazyHTML.attribute("aria-label") |> List.first()
        text = chip |> LazyHTML.text() |> String.trim()
        assert (is_binary(aria) and aria != "") or text != ""
      end

      # The "✕" glyph itself is hidden from assistive tech - the accessible
      # name comes from the label text/aria-label, not the mark.
      assert LazyHTML.query(document, ".filter-chip a span[aria-hidden]") != []
    end

    test "every tie-break working a reader can open is keyed, so a refresh can reopen it", %{
      world: world
    } do
      document =
        build_conn() |> get("/t/#{world.swiss}") |> html_response(200) |> LazyHTML.from_document()

      details = LazyHTML.query(document, "details.tb-detail")
      keys = details |> LazyHTML.attribute("data-detail") |> Enum.reject(&is_nil/1)

      assert Enum.count(details) > 0
      assert length(keys) == Enum.count(details)
      assert keys == Enum.uniq(keys)
    end

    test "the player card dialog can take focus", %{world: world} do
      document =
        build_conn() |> get("/t/#{world.swiss}") |> html_response(200) |> LazyHTML.from_document()

      assert document
             |> LazyHTML.query(
               ~s(#card-overlay [role="dialog"][aria-modal="true"][tabindex="-1"])
             )
             |> Enum.count() == 1
    end
  end

  describe "the admin panel" do
    setup do
      reset_admin_access()
      configure_access()
      {:ok, admin_world: AdminWorld.build()}
    end

    test "every page passes the audit", %{admin_world: world} do
      routes =
        for %{verb: :get, path: "/admin" <> _} = route <- OpenResultsWeb.Router.__routes__(),
            do: route

      failures =
        for route <- routes,
            path <- admin_pages(route, world),
            conn = admin_get(path),
            conn.status == 200,
            violations = A11y.audit(conn.resp_body, lang: "en"),
            violations != [] do
          "#{path}\n#{A11y.explain(violations)}"
        end

      assert failures == [], Enum.join(failures, "\n\n")
    end
  end

  # The same fan-out `admin_pages_test.exs` uses: every state an item can be in.
  defp admin_pages(route, world) do
    case route.path do
      "/admin/tournaments/:slug" <> rest ->
        for slug <- [world.pending, world.listed, world.hidden, world.unpublished],
            do: "/admin/tournaments/#{slug}" <> rest

      "/admin/installations/:id" <> rest ->
        for installation <- [world.active, world.suspended, world.revoked],
            do: "/admin/installations/#{installation.id}" <> rest

      "/admin/reports/:id" <> rest ->
        for report <- [world.open_report, world.resolved_report],
            do: "/admin/reports/#{report.id}" <> rest

      "/admin/address-blocks/:id" <> rest ->
        ["/admin/address-blocks/#{world.block.id}" <> rest]

      "/admin/switches/:key" ->
        ["/admin/switches/registration_open", "/admin/switches/public_publishing_paused"]

      "/admin/settings/:key" <> rest ->
        for key <- OpenResults.ServerSettings.keys(), do: "/admin/settings/#{key}" <> rest

      path ->
        [path]
    end
  end

  # The FIDE search panel renders only where this deployment can reach an
  # arbiter's list, and it is the one part of the entry form with a script
  # behind it - so the walk renders it.
  defp with_fide_search(fun) do
    saved =
      for key <- [:fide_lookup_endpoint, :fide_lookup_token],
          do: {key, Application.get_env(:openresults, key)}

    Application.put_env(:openresults, :fide_lookup_endpoint, "http://localhost:1")
    Application.put_env(:openresults, :fide_lookup_token, "a11y-test")

    try do
      fun.()
    after
      for {key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(:openresults, key),
          else: Application.put_env(:openresults, key, value)
      end
    end
  end
end
