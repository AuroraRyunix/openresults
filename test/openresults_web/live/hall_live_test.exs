defmodule OpenResultsWeb.HallLiveTest do
  @moduledoc """
  The hall display (`/t/:slug/hall`) as a screen: each view, the cycle and
  its pause, the arbiter's settings, the ticks it must respect, and a
  publish reaching it without a reload. The rules underneath are
  `OpenResultsWeb.HallTest`.

  Timers never fire here - a page lasts at least five seconds - so the cycle
  is turned by sending the LiveView the message its own timer would, with
  the cycle number the page carries in `data-cycle`.
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

  defp with_hall(payload, hall), do: put_in(payload, ["tournament", "hall"], hall)

  defp round5(payload, fun) do
    update_in(payload, ["rounds"], fn rounds ->
      Enum.map(rounds, fn
        %{"number" => 5} = round -> fun.(round)
        round -> round
      end)
    end)
  end

  defp clear_results(round),
    do:
      Map.update!(round, "boards", fn boards -> Enum.map(boards, &Map.put(&1, "result", nil)) end)

  # The swiss fixture with round 5 freshly paired: no result in yet.
  defp freshly_paired, do: round5(SnapshotPayloads.swiss(), &clear_results/1)

  # The swiss fixture as it stood before round 5 was published.
  defp before_round5 do
    update_in(SnapshotPayloads.swiss(), ["rounds"], fn rounds ->
      Enum.reject(rounds, &(&1["number"] == 5))
    end)
  end

  defp hall(conn, slug, query \\ ""), do: live(conn, "/t/#{slug}/hall" <> query)

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp current_view(view), do: attribute(view, "#hall", "data-view")

  # What the page's own timer would send when the page it started for ran out.
  defp advance(view) do
    cycle = view |> attribute("#hall", "data-cycle") |> String.to_integer()
    send(view.pid, {:advance, cycle})
    render(view)
    view
  end

  defp rows(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  describe "the views" do
    test "opens on the current round's pairings, big, with its heading", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug)

      assert current_view(view) == "pairings"
      assert has_element?(view, "#hall-name", "Gent Spring Open 2026")
      assert has_element?(view, "#hall-round", "5")
      assert has_element?(view, "#hall-final")
      assert rows(view, "#hall-pairings #hall-rows tr") == 5
      assert has_element?(view, "#board-1", "Müller, Jörg")
      assert has_element?(view, "#hall-clock[phx-hook]")
    end

    test "the name list is alphabetical with each player's board", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug)

      advance(view)

      assert current_view(view) == "names"
      assert rows(view, "#hall-names li") == 10

      first =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#hall-names li")
        |> Enum.at(0)
        |> LazyHTML.text()

      assert first =~ "Ångström"
      assert has_element?(view, "#name-1", "Bd 1")
    end

    test "the results view counts what is in", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug)

      view |> advance() |> advance()

      assert current_view(view) == "results"
      assert has_element?(view, "#hall-progress-count", "5 of 5")
      assert rows(view, "#hall-results #hall-rows tr") == 5
    end

    test "the standings show the top of the table", %{conn: conn} do
      slug = publish(with_hall(SnapshotPayloads.swiss(), %{"standings_top" => 4}))
      {:ok, view, _html} = hall(conn, slug)

      view |> advance() |> advance() |> advance()

      assert current_view(view) == "standings"
      assert rows(view, "#hall-standings #hall-rows tr") == 4
      assert has_element?(view, "#hall-standings", "2")
    end

    test "the arbiter's announcement is a view of its own", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_hall(%{"announcement" => "Prize giving at 18:00"})
        |> publish()

      {:ok, view, _html} = hall(conn, slug)
      view |> advance() |> advance() |> advance() |> advance()

      assert current_view(view) == "announcement"
      assert has_element?(view, "#hall-announcement-text", "Prize giving at 18:00")
    end

    test "a tournament with nothing to show yet says so", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> Map.put("rounds", [])
        |> Map.put("standings", %{})
        |> publish()

      {:ok, view, _html} = hall(conn, slug)

      assert has_element?(view, "#hall-idle")
    end
  end

  describe "the cycle" do
    test "comes round to the first view again", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug)

      view |> advance() |> advance() |> advance() |> advance()

      assert current_view(view) == "pairings"
    end

    test "a timer from a page that is gone is ignored", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug)

      stale = view |> attribute("#hall", "data-cycle") |> String.to_integer()
      render_keydown(view, "key", %{"key" => "ArrowRight"})
      assert current_view(view) == "names"

      send(view.pid, {:advance, stale})
      assert current_view(view) == "names"
    end

    test "a tap pauses on the page showing, and another resumes", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug)

      view |> element("#hall") |> render_click()
      assert has_element?(view, "#hall-paused")

      advance(view)
      assert current_view(view) == "pairings"

      view |> element("#hall") |> render_click()
      refute has_element?(view, "#hall-paused")
      advance(view)
      assert current_view(view) == "names"
    end

    test "the space bar pauses and the arrow keys step", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug)

      render_keydown(view, "key", %{"key" => " "})
      assert has_element?(view, "#hall-paused")

      render_keydown(view, "key", %{"key" => "ArrowLeft"})
      assert current_view(view) == "standings"
    end

    test "a freshly paired round holds on the pairings and the names", %{conn: conn} do
      slug = publish(freshly_paired())
      {:ok, view, _html} = hall(conn, slug)

      views =
        for _ <- 1..4 do
          advance(view)
          current_view(view)
        end

      assert Enum.uniq(views) |> Enum.sort() == ["names", "pairings"]
    end

    test "a new round jumps the screen to its pairings", %{conn: conn} do
      slug = publish(before_round5())
      {:ok, view, _html} = hall(conn, slug)

      view |> advance() |> advance()
      refute current_view(view) == "pairings"

      publish(freshly_paired())

      assert current_view(view) == "pairings"
      assert has_element?(view, "#hall-round", "5")
    end
  end

  describe "the arbiter's settings" do
    test "views switched off are skipped, and the page time is the arbiter's", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_hall(%{"names" => false, "results" => false, "page_seconds" => 30})
        |> publish()

      {:ok, view, _html} = hall(conn, slug)

      assert attribute(view, "#hall", "data-seconds") == "30"
      advance(view)
      assert current_view(view) == "standings"
    end

    test "?views= gives one screen only some views", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug, "?views=names")

      assert current_view(view) == "names"
      advance(view)
      assert current_view(view) == "names"
    end

    test "?theme=light is the high-contrast light theme; dark is the default", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      assert conn |> get("/t/#{slug}/hall?theme=light") |> html_response(200) =~
               ~s(data-theme="contrast")

      assert build_conn() |> get("/t/#{slug}/hall") |> html_response(200) =~
               ~s(data-theme="night")
    end

    test "speaks the reader's language", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug, "?lang=nl")

      assert has_element?(view, "#hall-view-name", "Paringen")
    end
  end

  describe "never more than the public pages show" do
    test "no ratings or titles when the arbiter hides them", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "display", "rating"], false)
        |> put_in(["tournament", "display", "title"], false)
        |> publish()

      {:ok, view, html} = hall(conn, slug)

      refute html =~ "2601"
      refute has_element?(view, ".hall-person-title")
    end

    test "no pairings, names or results when round pages are withheld", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "display", "pairings"], false)
        |> publish()

      {:ok, view, html} = hall(conn, slug)

      assert current_view(view) == "standings"
      refute has_element?(view, "#hall-round")
      advance(view)
      assert current_view(view) == "standings"
      refute html =~ "Bd 1"
    end

    test "no standings when they are withheld", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "display", "standings"], false)
        |> publish()

      {:ok, view, _html} = hall(conn, slug)

      views =
        for _ <- 1..4 do
          advance(view)
          current_view(view)
        end

      refute "standings" in views
    end

    test "no byes in the name list when byes are hidden", %{conn: conn} do
      with_bye =
        round5(SnapshotPayloads.swiss(), fn round ->
          round
          |> Map.update!("boards", &Enum.drop(&1, -1))
          |> Map.put("byes", [
            %{"player" => 10, "kind" => "half-point", "points" => 0.5},
            %{"player" => 9, "kind" => "half-point", "points" => 0.5}
          ])
        end)

      slug = with_bye |> put_in(["tournament", "display", "byes"], false) |> publish()
      {:ok, view, _html} = hall(conn, slug, "?views=names")

      refute has_element?(view, "#name-10")
      assert rows(view, "#hall-names li") == 8

      slug = publish(with_bye)
      {:ok, view, _html} = hall(conn, slug, "?views=names")
      assert has_element?(view, "#name-10", "half-point bye")
    end

    test "a round whose results are withheld shows no result and no results view", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> round5(&(&1 |> clear_results() |> Map.put("results_public", false)))
        |> publish()

      {:ok, view, _html} = hall(conn, slug)

      assert has_element?(view, "#hall-pairings .hall-note")

      views =
        for _ <- 1..3 do
          advance(view)
          current_view(view)
        end

      refute "results" in views
    end

    test "a hidden or unknown tournament is the standings page's own 404", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, _} = Moderation.hide(slug, %{email: "admin@example.invalid"})

      hidden = conn |> get("/t/#{slug}/hall") |> html_response(404)
      unknown = build_conn() |> get("/t/no-such-thing-at-all/hall") |> html_response(404)

      assert hidden =~ "No tournament has published under"
      assert unknown =~ "No tournament has published under"
    end
  end

  describe "live" do
    test "a published result shows without a reload", %{conn: conn} do
      slug = publish(freshly_paired())
      {:ok, view, _html} = hall(conn, slug)

      refute has_element?(view, "#board-1 .result .token")

      freshly_paired()
      |> round5(fn round ->
        update_in(round, ["boards"], fn [first | rest] ->
          [Map.put(first, "result", "0-1") | rest]
        end)
      end)
      |> publish()

      assert has_element?(view, "#board-1 .result .token", "0-1")
    end

    test "a new result is marked on the results view", %{conn: conn} do
      one_in =
        round5(freshly_paired(), fn round ->
          update_in(round, ["boards"], fn [first | rest] ->
            [Map.put(first, "result", "0-1") | rest]
          end)
        end)

      slug = publish(one_in)
      {:ok, view, _html} = hall(conn, slug, "?views=results")
      refute has_element?(view, "tr.is-fresh")

      one_in
      |> round5(fn round ->
        update_in(round, ["boards"], fn [a, b | rest] ->
          [a, Map.put(b, "result", "1-0") | rest]
        end)
      end)
      |> publish()

      assert has_element?(view, "#hall-progress-count", "2 of 5")
      assert has_element?(view, "tr.is-fresh#board-2")
    end

    test "a tournament hidden while on screen leaves it", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, view, _html} = hall(conn, slug)

      {:ok, _} = Moderation.hide(slug, %{email: "admin@example.invalid"})

      assert has_element?(view, "#hall-unavailable")
      refute has_element?(view, "#hall-pairings")
    end

    test "is rendered fresh on every request, never from the page cache", %{conn: conn} do
      slug = publish(freshly_paired())
      first = conn |> get("/t/#{slug}/hall")

      assert get_resp_header(first, "etag") == []

      refute first
             |> html_response(200)
             |> LazyHTML.from_document()
             |> LazyHTML.query("#board-1 .token")
             |> Enum.any?()

      publish(SnapshotPayloads.swiss())

      assert build_conn()
             |> get("/t/#{slug}/hall")
             |> html_response(200)
             |> LazyHTML.from_document()
             |> LazyHTML.query("#board-1 .token")
             |> LazyHTML.text() == "0-1"
    end
  end
end
