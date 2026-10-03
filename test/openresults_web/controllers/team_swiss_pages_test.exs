defmodule OpenResultsWeb.TeamSwissPagesTest do
  @moduledoc """
  A team Swiss with its matches - the fixture `snapshot_team_swiss.json`: five
  teams of three boards, three rounds, a pairing-allocated bye every round, a
  reserve who takes board 3 in round 3, and a board nobody sat at in round 2.

  The round page (boards listed once, grouped under their matches, the board
  within the match), the team page (roster, line-ups, the team's own score),
  the team list with its teams-by-board grid, and the team cross-table by
  round - and, for each, what the arbiter's switches withhold. The round robin
  and the not-yet-paired team Swiss are in `OpenResultsWeb.TeamPagesTest`.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.Tournament

  @slug "team-swiss-fixture"

  setup do
    {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_swiss())
    :ok
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  defp publish(slug, fun) do
    payload = SnapshotPayloads.team_swiss() |> put_in(["tournament", "slug"], slug) |> fun.()
    {:ok, _} = Snapshots.ingest(payload)
    slug
  end

  defp display(payload, key, value),
    do: put_in(payload, ["tournament", "display", key], value)

  describe "a round page" do
    test "lists every board once, grouped under its match, with the board within the match",
         %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/1") |> doc()

      # Two matches and the bye.
      assert count(document, "table.matches tbody tr") == 3
      assert count(document, "table.pairings tr.match-head") == 2
      assert count(document, "table.pairings tbody tr[id^=board-]") == 6
      # Bd is the place in the match, 1 2 3 and 1 2 3, never 1 2 3 4 5 6.
      assert texts(document, "table.pairings tbody tr[id^=board-] th") ==
               ["1", "2", "3", "1", "2", "3"]

      # No nested second copy of the boards.
      assert count(document, "table.matches details") == 0
      assert count(document, "table.nested") == 0
    end

    test "each match's number links to its group, and every anchor is on the page",
         %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/1") |> doc()

      hrefs =
        document
        |> LazyHTML.query("table.matches tbody th a")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "href"))

      assert hrefs == ["#match-1", "#match-2"]

      for href <- hrefs do
        assert count(document, "th#" <> String.trim_leading(href, "#")) == 1
      end
    end

    test "the header line names the teams and carries the match score", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/1") |> doc()

      [first | _] = texts(document, "table.pairings tr.match-head th")
      assert first =~ "Match 1"
      assert first =~ "Antwerp Knights"
      assert first =~ "Deurne"
      assert first =~ "2.5 - 0.5"
    end

    test "the bye is named and said to be scored as a drawn match", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/1") |> doc()

      [bye] = texts(document, "table.matches tbody tr:last-child td")
      assert bye =~ "Charleroi"
      assert bye =~ "has the bye"
      assert bye =~ "scored as a drawn match"
    end

    test "a board nobody sat at is in the match but is not a board of the page", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/2") |> doc()

      # Match 1: three boards. Match 2: two - the third is a forfeit win.
      assert texts(document, "table.pairings tbody tr[id^=board-] th") ==
               ["1", "2", "3", "1", "2"]

      assert count(document, "table.pairings tr.match-head") == 2
    end

    test "withheld results: the teams and the pairings show, no score does", %{conn: conn} do
      slug =
        publish("team-swiss-withheld", fn payload ->
          update_in(payload, ["rounds"], fn rounds ->
            Enum.map(rounds, fn
              %{"number" => 3} = round ->
                round
                |> Map.put("results_public", false)
                |> Map.update!("matches", fn matches ->
                  Enum.map(
                    matches,
                    &Map.merge(&1, %{"game_points" => nil, "match_points" => nil})
                  )
                end)
                |> Map.update!("boards", fn boards ->
                  Enum.map(boards, &(Map.merge(&1, %{"result" => nil}) |> Map.delete("points")))
                end)

              round ->
                round
            end)
          end)
        end)

      document = conn |> get(~p"/t/#{slug}/round/3") |> doc()

      assert count(document, "table.pairings tr.match-head") == 2
      refute Enum.any?(texts(document, "table.pairings tr.match-head th"), &(&1 =~ ~r/\d - \d/))

      assert texts(document, "table.pairings tr.match-head th")
             |> Enum.all?(&(&1 =~ "not yet published"))
    end
  end

  describe "the team page" do
    test "the roster shows the board each player played most, with games and points",
         %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/team/1") |> doc()

      assert texts(document, "#team-roster thead th") ==
               ["Bd", "Player", "Rating", "Games", "Points"]

      rows = texts(document, "#team-roster tbody tr")
      assert length(rows) == 4
      # Board, name, rating, games, points - the reserve sat on board 3 once.
      assert Enum.at(rows, 0) =~ ~r/^1 Antwerp Knights 1 \d+ 3 2\.5$/
      assert Enum.at(rows, 3) =~ ~r/^3 Antwerp Knights R 1950 1 1$/
    end

    test "the matches table is the line-up of every round, board by board", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/team/1") |> doc()

      assert texts(document, "#team-matches thead th") ==
               ["Rd", "Opponent", "Score", "Board 1", "Board 2", "Board 3"]

      assert count(document, "#team-matches tbody tr") == 3

      round3 = texts(document, "#team-round-3 td")
      assert Enum.at(round3, 0) == "Charleroi"
      # The reserve took board 3; board 3's player scored the point.
      assert Enum.at(round3, 4) =~ "Antwerp Knights R"
      assert Enum.at(round3, 4) =~ "1"
    end

    test "the score is the team's own, its game points first", %{conn: conn} do
      # Eupen is team B in round 1 (1 against 2): 2 - 1 from its own side,
      # where team A's side would read 1 - 2.
      document = conn |> get(~p"/t/#{@slug}/team/5") |> doc()
      [round1 | _] = texts(document, "#team-round-1 td")
      assert round1 == "Brugse SK"
      assert texts(document, "#team-round-1 td:nth-child(3)") |> hd() =~ "2 - 1"
    end

    test "a bye is a row with no opponent and no boards", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/team/3") |> doc()

      [opponent | _] = texts(document, "#team-round-1 td")
      assert opponent == "bye"
    end

    test "a board nobody sat at shows as no game", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/team/3") |> doc()

      round2 = texts(document, "#team-round-2 td")
      # Board 3 of Charleroi's round 2: nobody there.
      assert Enum.at(round2, 4) =~ "no game"
    end

    test "pairings switched off: the history stays, the line-ups go", %{conn: conn} do
      slug = publish("team-swiss-nopairings", &display(&1, "pairings", false))
      document = conn |> get(~p"/t/#{slug}/team/1") |> doc()

      assert texts(document, "#team-matches thead th") == ["Rd", "Opponent", "Score"]
      assert count(document, "#team-matches tbody tr") == 3
      # Nothing derived from boards: no board column, no seat scores.
      assert count(document, ".seat-score") == 0
    end

    test "results withheld: the line-up shows, what they scored does not", %{conn: conn} do
      slug =
        publish("team-swiss-lineup-only", fn payload ->
          update_in(payload, ["rounds"], fn rounds ->
            Enum.map(rounds, fn
              %{"number" => 3} = round ->
                round
                |> Map.put("results_public", false)
                |> Map.update!("boards", fn boards ->
                  Enum.map(boards, &(&1 |> Map.put("result", nil) |> Map.delete("points")))
                end)

              round ->
                round
            end)
          end)
        end)

      document = conn |> get(~p"/t/#{slug}/team/1") |> doc()
      round3 = texts(document, "#team-round-3 td")
      assert Enum.at(round3, 2) =~ "Antwerp Knights 1"
      assert count(document, "#team-round-3 .seat-score") == 0
      assert count(document, "#team-round-1 .seat-score") == 3
    end

    test "player cards switched off: names, no links to a card", %{conn: conn} do
      slug = publish("team-swiss-nocards", &display(&1, "player_cards", false))
      document = conn |> get(~p"/t/#{slug}/team/1") |> doc()

      assert count(document, "#team-roster a.player") == 0
      assert count(document, "#team-matches a.player") == 0
      assert texts(document, "#team-roster tbody tr") |> hd() =~ "Antwerp Knights 1"
    end

    test "standings switched off: the page is withheld", %{conn: conn} do
      slug = publish("team-swiss-nostandings", &display(&1, "standings", false))
      conn |> get(~p"/t/#{slug}/team/1") |> html_response(404)
    end
  end

  describe "the team list" do
    test "teams in the order of the standings, with places, points, captain and roster",
         %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/teams") |> doc()

      assert texts(document, "#team-list thead th") ==
               ["#", "Team", "MP", "GP", "Captain", "Players"]

      assert texts(document, "#team-list tbody th a") ==
               ["Antwerp Knights", "Eupen", "Brugse SK", "Charleroi", "Deurne"]

      [first | _] = texts(document, "#team-list tbody tr")
      assert first =~ ~r/^1 Antwerp Knights 6 7 Jan Peeters /
      # The roster is in board order, the reserve last.
      assert String.replace(first, " ,", ",") =~
               "Antwerp Knights 1, Antwerp Knights 2, Antwerp Knights 3, Antwerp Knights R"
    end

    test "the teams-by-board grid puts each player on the board they played most",
         %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/teams") |> doc()

      assert texts(document, "#team-boards thead th") == ["Team", "Board 1", "Board 2", "Board 3"]
      assert count(document, "#team-boards tbody tr") == 5

      # Antwerp: one player on boards 1 and 2, two on board 3 - the reserve
      # took over - each with points/games.
      [antwerp | _] = LazyHTML.query(document, "#team-boards tbody tr") |> Enum.to_list()
      assert count(antwerp, ".team-board-entry") == 4

      assert antwerp |> LazyHTML.query("td:nth-child(2) .team-board-entry") |> LazyHTML.text() =~
               "2.5/3"
    end

    test "linked from every page of the event, and marked current on its own",
         %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/teams") |> doc()
      assert texts(document, "#teams-link") == ["Teams"]

      assert LazyHTML.attribute(LazyHTML.query(document, "#teams-link"), "aria-current") == [
               "page"
             ]

      document = conn |> get(~p"/t/#{@slug}") |> doc()
      assert texts(document, "#teams-link") == ["Teams"]
    end

    test "standings switched off: withheld, and not linked", %{conn: conn} do
      slug = publish("team-swiss-list-nostandings", &display(&1, "standings", false))

      conn |> get(~p"/t/#{slug}/teams") |> html_response(404)
      refute conn |> get(~p"/t/#{slug}/round/1") |> html_response(200) =~ "teams-link"
    end

    test "player cards switched off: the roster is names", %{conn: conn} do
      slug = publish("team-swiss-list-nocards", &display(&1, "player_cards", false))
      document = conn |> get(~p"/t/#{slug}/teams") |> doc()

      assert count(document, "#team-list a.player") == 0
      assert count(document, "#team-boards a.player") == 0
    end

    test "an individual tournament has no team list", %{conn: conn} do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.swiss())
      slug = SnapshotPayloads.swiss()["tournament"]["slug"]

      conn |> get(~p"/t/#{slug}/teams") |> html_response(404)
    end

    test "in Dutch and in French", %{conn: conn} do
      nl = conn |> get(~p"/t/#{@slug}/teams?lang=nl") |> doc()
      assert texts(nl, "main h2, section h2") |> Enum.member?("Ploegen")
      assert texts(nl, "#team-boards thead th") |> Enum.member?("Bord 1")

      fr = conn |> get(~p"/t/#{@slug}/teams?lang=fr") |> doc()
      assert texts(fr, "main h2, section h2") |> Enum.member?("Équipes")
      assert texts(fr, "#team-boards thead th") |> Enum.member?("Échiquier 1")
    end
  end

  describe "the team cross-table by round" do
    test "a row per team, in the order of the standings, a cell per round", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/crosstable") |> doc()

      assert count(document, "#team-crosstable tbody tr") == 5

      assert texts(document, "#team-crosstable tbody th a") ==
               ["Antwerp Knights", "Eupen", "Brugse SK", "Charleroi", "Deurne"]

      assert texts(document, "#team-crosstable thead th a") == ["1", "2", "3"]
      # The standings' own MP, GP and rank close the row.
      [antwerp | _] = LazyHTML.query(document, "#team-crosstable tbody tr") |> Enum.to_list()

      assert antwerp
             |> LazyHTML.query("td.num")
             |> Enum.map(&LazyHTML.text/1)
             |> Enum.map(&String.trim/1) == ["1", "6", "7", "1"]
    end

    test "each cell: the opponent, the colour on board 1, the score from this team's side",
         %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/crosstable") |> doc()

      [antwerp, eupen | _] =
        LazyHTML.query(document, "#team-crosstable tbody tr") |> Enum.to_list()

      assert antwerp |> LazyHTML.query(".xt-opp") |> Enum.map(&LazyHTML.text/1) == ["4", "5", "3"]

      assert antwerp |> LazyHTML.query(".xt-colour") |> Enum.map(&LazyHTML.text/1) == [
               "w",
               "w",
               "w"
             ]

      assert antwerp
             |> LazyHTML.query(".xt-score")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == [
               "2.5-0.5",
               "2-1",
               "2.5-0.5"
             ]

      # Eupen was team B against Brugse SK in round 1 - Black on board 1 - and
      # its score is read from its own side.
      assert eupen |> LazyHTML.query(".xt-colour") |> Enum.map(&LazyHTML.text/1) |> hd() == "b"

      assert eupen
             |> LazyHTML.query(".xt-score")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
             |> hd() == "2-1"
    end

    test "the running match and game points, added up round by round", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/crosstable") |> doc()
      [antwerp | _] = LazyHTML.query(document, "#team-crosstable tbody tr") |> Enum.to_list()

      running =
        antwerp
        |> LazyHTML.query(".xt-running [aria-hidden]")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert running == ["2 · 2.5", "4 · 4.5", "6 · 7"]
    end

    test "a bye is a cell too, scored as a drawn match", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/crosstable") |> doc()
      charleroi = LazyHTML.query(document, "#team-crosstable tbody tr") |> Enum.at(3)

      [round1 | _] = charleroi |> LazyHTML.query("td.xt-cell") |> Enum.to_list()
      assert LazyHTML.text(round1) =~ "bye"
      assert LazyHTML.text(round1) =~ "1 · 1.5"
      assert count(round1, ".xt-colour") == 0
    end

    test "the player cross-table stays below, with its own heading", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/crosstable") |> doc()

      assert texts(document, "section h2") == ["Team cross-table", "Player cross-table"]
      assert count(document, "table.crosstable") == 2
    end

    test "only the rounds the standings reach, and whose results are public", %{conn: conn} do
      slug =
        publish("team-swiss-xt-gated", fn payload ->
          payload
          |> put_in(["standings", "after_round"], 2)
          |> put_in(["team_standings", "after_round"], 2)
        end)

      document = conn |> get(~p"/t/#{slug}/crosstable") |> doc()
      assert texts(document, "#team-crosstable thead th a") == ["1", "2"]

      slug =
        publish("team-swiss-xt-withheld", fn payload ->
          update_in(payload, ["rounds"], fn rounds ->
            Enum.map(rounds, fn
              %{"number" => 3} = round -> Map.put(round, "results_public", false)
              round -> round
            end)
          end)
        end)

      document = conn |> get(~p"/t/#{slug}/crosstable") |> doc()
      assert texts(document, "#team-crosstable thead th a") == ["1", "2"]
    end

    test "a running total stops at the first match whose score is not known", %{conn: _conn} do
      payload =
        SnapshotPayloads.team_swiss()
        |> update_in(["rounds", Access.at(1), "matches", Access.at(0)], fn match ->
          Map.merge(match, %{"match_points" => nil})
        end)

      table = Tournament.team_round_crosstable(payload)
      antwerp = Enum.find(table.rows, &(&1.no == 1))

      assert Enum.map(antwerp.cells, & &1.total_mp) == [2.0, nil, nil]
      assert Enum.map(antwerp.cells, & &1.total_gp) == [2.5, 4.5, 7.0]
    end

    test "pairings or the cross-table switched off: the page is withheld", %{conn: conn} do
      slug = publish("team-swiss-xt-nopairings", &display(&1, "pairings", false))
      conn |> get(~p"/t/#{slug}/crosstable") |> html_response(404)

      slug = publish("team-swiss-xt-off", &display(&1, "crosstable", false))
      conn |> get(~p"/t/#{slug}/crosstable") |> html_response(404)
    end

    test "a round robin gets the grid on the standings page, not this table", %{conn: conn} do
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_round_robin())
      slug = SnapshotPayloads.team_round_robin()["tournament"]["slug"]

      document = conn |> get(~p"/t/#{slug}/crosstable") |> doc()
      assert count(document, "#team-crosstable") == 0
    end

    test "in Dutch and in French", %{conn: conn} do
      nl = conn |> get(~p"/t/#{@slug}/crosstable?lang=nl") |> doc()
      assert texts(nl, "section h2") == ["Ploegentabel", "Kruistabel van de spelers"]

      fr = conn |> get(~p"/t/#{@slug}/crosstable?lang=fr") |> doc()

      assert texts(fr, "section h2") == [
               "Tableau croisé des équipes",
               "Grille américaine des joueurs"
             ]
    end
  end

  describe "the standings page of a team Swiss" do
    test "shows the team standings, not the round robin grid", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}") |> doc()

      assert texts(document, "table.standings tbody th a") |> hd() == "Antwerp Knights"
      refute conn |> get(~p"/t/#{@slug}") |> html_response(200) =~ "Team cross-table"
    end

    test "says nothing about pairing players individually", %{conn: conn} do
      for path <- ["", "/round/1", "/teams", "/crosstable", "/team/1"] do
        html = conn |> get("/t/#{@slug}#{path}") |> html_response(200)
        refute html =~ ~r/player by player|individually|phase 1/i
      end
    end
  end

  describe "Tournament.match_slots/2" do
    test "numbers a match's boards within the match and flags a seat nobody filled" do
      payload = SnapshotPayloads.team_swiss()
      round = Tournament.round(payload, 2)
      match = round |> Tournament.matches() |> Enum.find(&(&1["number"] == 2))

      assert [
               %{k: 1, number: 4, board: %{}},
               %{k: 2, number: 5, board: %{}},
               %{k: 3, number: 6, board: nil}
             ] = Tournament.match_slots(round, match)
    end

    test "board_positions, when sent, place each board - a hidden board shifts nothing" do
      payload = SnapshotPayloads.team_swiss()
      round = Tournament.round(payload, 2)
      match = round |> Tournament.matches() |> Enum.find(&(&1["number"] == 2))

      # Board 4 hidden: the publisher leaves it out of both lists.
      match =
        match
        |> Map.put("boards", [5, 6])
        |> Map.put("board_positions", [%{"board" => 5, "k" => 2}, %{"board" => 6, "k" => 3}])

      assert [%{k: 2, number: 5}, %{k: 3, number: 6}] = Tournament.match_slots(round, match)

      # Without the field, the older reading numbers by position.
      assert [%{k: 1, number: 5}, %{k: 2, number: 6}] =
               Tournament.match_slots(round, Map.delete(match, "board_positions"))
    end

    test "team_boards is read when sent" do
      payload = SnapshotPayloads.team_swiss()
      assert Tournament.team_boards(put_in(payload, ["tournament", "team_boards"], 3)) == 3

      assert Tournament.team_boards(
               update_in(payload, ["tournament"], &Map.delete(&1, "team_boards"))
             ) == nil
    end
  end
end
