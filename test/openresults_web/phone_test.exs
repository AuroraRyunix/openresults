defmodule OpenResultsWeb.PhoneTest do
  @moduledoc """
  The parts of the phone layout a server-rendered page can prove: the
  viewport, the search that is on every table page, and the classes the
  stylesheet's phone rules hang on. The rules themselves are read out of
  `assets/css/app.css`, the way `contrast_test.exs` reads the tokens - a
  rename on either side fails here rather than quietly dropping a phone
  layout.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots}

  @css Path.expand("../../assets/css/app.css", __DIR__)

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp doc(conn), do: LazyHTML.from_document(html_response(conn, 200))

  defp present?(document, selector),
    do: not (document |> LazyHTML.query(selector) |> Enum.empty?())

  defp hiding(payload, keys) do
    update_in(payload, ["tournament", "display"], fn display ->
      Enum.reduce(keys, display, &Map.put(&2, &1, false))
    end)
  end

  # Comments out, so a selector named in prose never counts as a rule.
  defp stylesheet, do: Regex.replace(~r{/\*.*?\*/}s, File.read!(@css), "")

  test "the viewport reaches the screen's edges and the page keeps clear of them", %{conn: conn} do
    slug = publish(SnapshotPayloads.swiss())

    [content] =
      conn
      |> get(~p"/t/#{slug}")
      |> doc()
      |> LazyHTML.query("meta[name=viewport]")
      |> LazyHTML.attribute("content")

    assert content =~ "width=device-width"
    assert content =~ "viewport-fit=cover"
    # Zoom is never taken away: a reader who needs bigger type pinches.
    refute content =~ "user-scalable"
    refute content =~ "maximum-scale"
    assert stylesheet() =~ "env(safe-area-inset-left"
  end

  describe "finding your own name" do
    test "every table page has the player search", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      for path <- [~p"/t/#{slug}", ~p"/t/#{slug}/round/1", ~p"/t/#{slug}/crosstable"] do
        document = conn |> get(path) |> doc()
        assert present?(document, "#filter-bar #player-search[type=search][name=q]"), path
      end
    end

    test "a round with nothing to filter by still offers the search", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> hiding(["club", "federation", "category"])
        |> put_in(["tournament", "categories"], [])
        |> publish()

      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert present?(document, "#player-search")
      # No empty disclosure beside it.
      refute present?(document, "details.filter-disclosure")
    end

    test "searching a round keeps the matching board and marks the seat", %{conn: conn} do
      payload = SnapshotPayloads.swiss()
      slug = publish(payload)
      [round | _] = payload["rounds"]
      board = hd(round["boards"])
      name = Enum.find(payload["players"], &(&1["no"] == board["white"]))["name"]

      document = conn |> get(~p"/t/#{slug}/round/#{round["number"]}?#{[q: name]}") |> doc()

      assert present?(document, "#board-#{board["board"]} td.seat.pairing-match")
    end

    test "the search bar stays on screen on a phone", _context do
      css = stylesheet()

      assert css =~
               ~r/@media screen and \(max-width: 48rem\)\s*\{\s*\.filter-bar\s*\{[^}]*position:\s*sticky/
    end
  end

  describe "the pairings on a phone" do
    test "the ratings and points going in are the columns a phone drops", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert present?(document, "table.pairings th.col-rating")
      assert present?(document, "table.pairings td.col-rating")
      assert present?(document, "table.pairings th.col-pts")
      assert present?(document, "table.pairings td.col-pts")

      assert document
             |> LazyHTML.query("table.pairings > tbody > tr:first-child > td.seat")
             |> Enum.count() == 2

      assert stylesheet() =~
               ~r/\.pairings \.col-rating,\s*\.pairings \.col-pts\s*\{\s*display:\s*none/
    end
  end

  describe "touch and type" do
    test "no text box is under 16px where iOS would zoom on it" do
      css = stylesheet()

      [_, block] =
        Regex.run(
          ~r/@media screen and \(pointer: coarse\), screen and \(max-width: 40rem\)\s*\{(.*?)\}\s*\}/s,
          css
        )

      for selector <- [
            ".index-search-input",
            ".filter-search-input",
            ".field textarea",
            ".fide-search input"
          ] do
        assert block =~ selector, selector
      end

      assert block =~ ~r/font-size:\s*1rem/
    end

    test "controls a finger uses are at least 44px on a touch screen" do
      css = stylesheet()
      [_, block] = Regex.run(~r/@media screen and \(pointer: coarse\)\s*\{(.*?)\n\}/s, css)

      for selector <- [
            ".chip",
            ".filter-summary",
            ".theme-picker-trigger",
            ".card-close",
            ".lang-opt"
          ] do
        assert block =~ selector, selector
      end

      assert block =~ "min-height: 2.75rem"
    end
  end
end
