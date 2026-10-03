defmodule OpenResultsWeb.TeamHallTest do
  @moduledoc """
  The hall display and the projector view for a team event: matches, the colour
  each team has on board 1, and "match 3, board 2" where a board is named.
  The generic rules are in `OpenResultsWeb.HallTest` and `HallLiveTest`.
  """
  use OpenResultsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.Hall

  @slug "team-swiss-fixture"

  defp build(payload), do: Hall.build(payload, Hall.settings(payload))

  defp page(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
  end

  defp texts(nodes),
    do: Enum.map(nodes, &(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))

  describe "Hall.build/2 for a team Swiss" do
    test "the newest round's matches, with the colour each team has on board 1" do
      data = build(SnapshotPayloads.team_swiss())

      assert Hall.matches?(data)
      assert [m1, m2, bye] = data.matches
      assert {m1.team_a, m1.team_b} == {"Antwerp Knights", "Charleroi"}
      assert {m1.colour_a, m1.colour_b} == {:white, :black}
      assert {m1.score_a, m1.score_b} == {2.5, 0.5}
      assert {m2.team_a, m2.team_b} == {"Eupen", "Deurne"}
      assert bye.bye?
      assert {bye.colour_a, bye.colour_b} == {nil, nil}
    end

    test "boards are named by match and board, not by the round-wide number" do
      data = build(SnapshotPayloads.team_swiss())

      assert Enum.map(data.boards, & &1.label) == ["1/1", "1/2", "1/3", "2/1", "2/2", "2/3"]
      assert Enum.map(data.boards, & &1.k) == [1, 2, 3, 1, 2, 3]
      assert data.reported |> Enum.map(& &1.label) == Enum.map(data.boards, & &1.label)

      assert data.names |> Enum.map(&{&1.match, &1.k}) |> Enum.uniq() |> Enum.sort() ==
               for(m <- 1..2, k <- 1..3, do: {m, k})
    end

    test "results not public: the teams and colours show, no score does" do
      payload =
        update_in(SnapshotPayloads.team_swiss(), ["rounds"], fn rounds ->
          Enum.map(rounds, fn
            %{"number" => 3} = round -> Map.put(round, "results_public", false)
            round -> round
          end)
        end)
        |> update_in(["rounds", Access.at(2), "matches"], fn matches ->
          Enum.map(matches, &Map.merge(&1, %{"game_points" => nil, "match_points" => nil}))
        end)

      data = build(payload)
      assert Enum.all?(data.matches, &(&1.score_a == nil and &1.score_b == nil))
      assert hd(data.matches).colour_a == :white
      assert data.reported == []
    end

    test "pairings switched off: no matches, no names" do
      payload =
        put_in(SnapshotPayloads.team_swiss(), ["tournament", "display", "pairings"], false)

      data = build(payload)

      assert data.matches == []
      assert data.boards == []
    end

    test "an individual tournament has no matches and keeps its board labels" do
      data = build(SnapshotPayloads.swiss())

      refute Hall.matches?(data)
      assert Enum.all?(data.boards, &(&1.match == nil))
    end
  end

  describe "the screens" do
    setup do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss())
      :ok
    end

    test "the hall's pairings view is the matches, with colours and scores", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/t/#{@slug}/hall")

      assert [_, _, _] = page(view, "table.hall-matches tbody tr") |> Enum.to_list()
      first = page(view, "table.hall-matches tbody tr") |> Enum.at(0) |> LazyHTML.text()
      assert first =~ "Antwerp Knights"
      assert first =~ "White"
      assert first =~ "Charleroi"
      assert first =~ "Black"
      assert first =~ "2.5 - 0.5"
      assert page(view, "table.hall-matches tbody tr") |> Enum.at(2) |> LazyHTML.text() =~ "bye"
    end

    test "the name list says which match and which board", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/t/#{@slug}/hall?views=names")

      seats = page(view, ".hall-name-board") |> texts()
      assert "Match 1, Bd 1" in seats
      assert "Match 2, Bd 3" in seats
      refute Enum.any?(seats, &(&1 =~ ~r/^Bd \d/))
    end

    test "the results view labels boards match/board", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/t/#{@slug}/hall?views=results")

      assert page(view, "table.hall-boards thead th") |> texts() |> hd() == "Match/Bd"
      labels = page(view, "table.hall-boards tbody th") |> texts()
      assert "1/1" in labels
      assert "2/3" in labels
    end

    test "the projector view shows the matches too", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/t/#{@slug}/projector")

      assert page(view, "table.hall-matches tbody tr") |> Enum.count() == 3
    end

    test "in French the colours and headings are French", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/t/#{@slug}/hall?lang=fr")

      first = page(view, "table.hall-matches tbody tr") |> Enum.at(0) |> LazyHTML.text()
      assert first =~ "Blancs"
      assert first =~ "Noirs"
    end
  end
end
