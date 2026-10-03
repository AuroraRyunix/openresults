defmodule OpenResultsWeb.ScreensTest do
  @moduledoc """
  The two hall screens as a pair: the cards that link them from the foot of the
  tournament pages, the tournament-level projector view (`/t/:slug/projector`,
  which follows the newest round and updates by itself), the full-screen and
  colour controls both carry, and the clock's seconds. The hall display's own
  behaviour is `OpenResultsWeb.HallLiveTest`.
  """

  use OpenResultsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenResults.Moderation
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  defp publish(payload) do
    {:ok, _snapshot} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp before_round5 do
    update_in(SnapshotPayloads.swiss(), ["rounds"], fn rounds ->
      Enum.reject(rounds, &(&1["number"] == 5))
    end)
  end

  defp count(html, selector) do
    html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  describe "the links at the foot of the tournament pages" do
    test "each screen is linked once, as its own card, on the overview pages", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      for path <- ["/t/#{slug}", "/t/#{slug}/round/5", "/t/#{slug}/round/2"] do
        html = conn |> get(path) |> html_response(200)

        assert count(html, "#screens #projector-link.screen-card") == 1, path
        assert count(html, "#screens #hall-display-link.screen-card") == 1, path
        assert count(html, "#projector-link .screen-card-icon") == 1
        assert count(html, "#projector-link .screen-card-title") == 1
        assert count(html, "#projector-link .screen-card-desc") == 1
        assert count(html, "#hall-display-link .screen-card-desc") == 1
        assert count(html, ~s(a[href="/t/#{slug}/projector"])) == 1
        assert count(html, ~s(a[href="/t/#{slug}/hall"])) == 1
      end
    end

    test "a round page no longer carries a per-round projector link", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      html = conn |> get("/t/#{slug}/round/3") |> html_response(200)

      assert count(html, ~s(a[href*="display=1"])) == 0
    end

    test "a player's card does not repeat them", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      html = conn |> get("/t/#{slug}/player/1") |> html_response(200)

      assert count(html, "#screens") == 0
    end

    test "nothing to project when the arbiter hides the pairings", %{conn: conn} do
      slug =
        publish(put_in(SnapshotPayloads.swiss(), ["tournament", "display", "pairings"], false))

      html = conn |> get("/t/#{slug}") |> html_response(200)

      assert count(html, "#projector-link") == 0
    end
  end

  describe "the projector view" do
    test "shows the newest round's boards, large, and nothing else", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, html} = live(conn, "/t/#{slug}/projector")

      assert attribute(view, "#hall", "data-screen") == "projector"
      assert has_element?(view, "#hall.is-projector")
      assert has_element?(view, "#hall-round", "5")
      assert has_element?(view, "#board-1", "Müller, Jörg")
      assert html =~ "Projector view"
      refute has_element?(view, "#hall-standings")
      refute has_element?(view, "#hall-names")
    end

    test "?views= does not turn it into the hall display", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = live(conn, "/t/#{slug}/projector?views=standings")

      assert attribute(view, "#hall", "data-view") == "pairings"
    end

    test "follows a new round and a new result by itself", %{conn: conn} do
      slug = publish(before_round5())
      {:ok, view, _html} = live(conn, "/t/#{slug}/projector")

      refute has_element?(view, "#hall-round", "5")
      refute has_element?(view, "#hall-final")

      publish(SnapshotPayloads.swiss())

      assert has_element?(view, "#hall-round", "5")
      assert has_element?(view, "#hall-final")

      publish(
        update_in(SnapshotPayloads.swiss(), ["rounds"], fn rounds ->
          Enum.map(rounds, fn
            %{"number" => 5} = round ->
              update_in(round, ["boards"], fn [first | rest] ->
                [Map.put(first, "result", "0-1") | rest]
              end)

            round ->
              round
          end)
        end)
      )

      assert has_element?(view, "#board-1 .result .token", "0-1")
    end

    test "is a 404 for a hidden or unknown tournament, and leaves a screen when hidden",
         %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = live(conn, "/t/#{slug}/projector")

      {:ok, _} = Moderation.hide(slug, %{email: "admin@example.invalid"})

      assert has_element?(view, "#hall-unavailable")
      refute has_element?(view, "#board-1")

      assert build_conn() |> get("/t/#{slug}/projector") |> html_response(404) =~
               "No tournament has published under"

      assert build_conn() |> get("/t/no-such-thing/projector") |> html_response(404) =~
               "No tournament has published under"
    end

    test "shows no boards when the arbiter hides the pairings", %{conn: conn} do
      slug =
        publish(put_in(SnapshotPayloads.swiss(), ["tournament", "display", "pairings"], false))

      {:ok, view, _html} = live(conn, "/t/#{slug}/projector")

      refute has_element?(view, "#board-1")
      assert has_element?(view, "#hall-idle")
    end

    test "withholds results the arbiter has not published", %{conn: conn} do
      payload =
        update_in(SnapshotPayloads.swiss(), ["rounds"], fn rounds ->
          Enum.map(rounds, fn
            %{"number" => 5} = round ->
              Map.update!(round, "boards", fn boards ->
                Enum.map(boards, &Map.put(&1, "result", nil))
              end)

            round ->
              round
          end)
        end)

      slug = publish(payload)
      {:ok, view, _html} = live(conn, "/t/#{slug}/projector")

      refute has_element?(view, "#board-1 .result .token")
    end

    test "is not served from the page cache", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      assert get_resp_header(get(conn, "/t/#{slug}/projector"), "etag") == []
    end

    test "a round's old ?display=1 link keeps showing that round, as before", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      html = conn |> get("/t/#{slug}/round/2?display=1") |> html_response(200)

      assert count(html, "[data-projector]") == 1
      assert html =~ "Round 2"
    end
  end

  describe "the controls" do
    for path <- ["hall", "projector"] do
      test "/#{path} carries the full-screen button and the colour choice", %{conn: conn} do
        slug = publish(SnapshotPayloads.swiss())
        {:ok, view, _html} = live(conn, "/t/#{slug}/#{unquote(path)}")

        assert has_element?(view, "#screen-tools[phx-hook]")
        assert has_element?(view, "#fullscreen-toggle[hidden]")
        assert has_element?(view, "#fullscreen-toggle .screen-icon")
        assert has_element?(view, "#fullscreen-toggle .screen-btn-label")
        assert has_element?(view, "#theme-black[aria-pressed=true]")
        assert has_element?(view, "#theme-white[aria-pressed=false]")
        assert has_element?(view, "#theme-ultra[aria-pressed=false]")
      end
    end

    test "?theme= picks black, white or ultra; light is white; black is the default",
         %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      for {query, theme} <- [
            {"", "night"},
            {"?theme=black", "night"},
            {"?theme=white", "contrast"},
            {"?theme=light", "contrast"},
            {"?theme=ultra", "ultra"},
            {"?theme=nonsense", "night"}
          ],
          screen <- ["hall", "projector"] do
        html = conn |> get("/t/#{slug}/#{screen}#{query}") |> html_response(200)
        assert html =~ ~s(data-theme="#{theme}"), "#{screen}#{query}"
      end
    end

    test "a theme from the URL is flagged so a remembered choice does not override it",
         %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      {:ok, view, _html} = live(conn, "/t/#{slug}/hall?theme=ultra")
      assert attribute(view, "#screen-tools", "data-theme-from-url") == "true"
      assert has_element?(view, "#theme-ultra[aria-pressed=true]")

      {:ok, view, _html} = live(build_conn(), "/t/#{slug}/hall")
      assert attribute(view, "#screen-tools", "data-theme-from-url") == "false"
    end

    test "the clock is HH:MM:SS, ticked by the browser", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = live(conn, "/t/#{slug}/hall")

      assert has_element?(view, ~s(#hall-clock[phx-hook][data-format="HH:MM:SS"]))
    end
  end
end
