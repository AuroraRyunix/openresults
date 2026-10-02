defmodule OpenResultsWeb.PostponedGamesTest do
  @moduledoc """
  Postponed games, as a spectator sees them - `boards[].postponed`,
  `boards[].postponed_date`, `matches[].postponed_boards` and
  `standings.provisional`/`postponed_games` in `docs/snapshot-schema.md`.

  The individual fixture is the ordinary Swiss with two of round 2's boards
  postponed - one with an agreed date, one without - and one played; the team
  fixture is the round robin with one board of match 1 postponed.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.Tournament

  @slug "postponed-swiss"
  @team_slug "postponed-team"

  setup do
    swiss = postponed_swiss()
    team = postponed_team()

    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, _} = Snapshots.ingest(team)

    {:ok, swiss: swiss, team: team}
  end

  # Round 2: board 1 (2 v 1) played, board 2 (6 v 3) postponed to an agreed
  # date, board 4 (8 v 9) postponed with no date yet.
  defp postponed_swiss do
    SnapshotPayloads.swiss()
    |> put_in(["tournament", "slug"], @slug)
    |> update_in(["rounds"], fn rounds ->
      Enum.map(rounds, fn
        %{"number" => 2} = round ->
          Map.update!(round, "boards", fn boards ->
            Enum.map(boards, fn
              %{"board" => 2} = board ->
                Map.merge(board, %{
                  "result" => nil,
                  "postponed" => true,
                  "postponed_date" => "2026-03-20"
                })

              %{"board" => 4} = board ->
                Map.merge(board, %{"result" => nil, "postponed" => true})

              board ->
                board
            end)
          end)

        round ->
          round
      end)
    end)
    |> update_in(["standings"], &Map.merge(&1, %{"provisional" => true, "postponed_games" => 2}))
  end

  # Match 1 of round 1 is boards 1 and 2; board 2 (8 v 2) is postponed, and
  # the match's points are OpenPairings' provisional ones, sent as they are.
  defp postponed_team do
    SnapshotPayloads.team_round_robin()
    |> put_in(["tournament", "slug"], @team_slug)
    |> update_in(["rounds", Access.at(0)], fn round ->
      round
      |> Map.update!("boards", fn boards ->
        Enum.map(boards, fn
          %{"board" => 2} = board -> Map.merge(board, %{"result" => nil, "postponed" => true})
          board -> board
        end)
      end)
      |> Map.update!("matches", fn matches ->
        Enum.map(matches, fn
          %{"number" => 1} = match -> Map.put(match, "postponed_boards", 1)
          match -> match
        end)
      end)
    end)
  end

  # The same snapshot with its standings stopping after `round` and carrying
  # exactly these totals - what OpenPairings publishes after pricing the
  # postponed games by the tournament's rules and point system.
  defp standings_after(payload, round, totals) do
    rows =
      totals
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.map(fn {{no, points}, rank} ->
        %{"rank" => rank, "player" => no, "points" => points, "tiebreaks" => []}
      end)

    update_in(payload, ["standings"], fn standings ->
      standings |> Map.put("after_round", round) |> Map.put("rows", rows)
    end)
  end

  defp publish(payload), do: {:ok, _snapshot} = Snapshots.ingest(payload)

  defp doc(conn), do: LazyHTML.from_document(html_response(conn, 200))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  defp attributes(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp without_dates(payload), do: put_in(payload, ["tournament", "display", "dates"], false)

  describe "a round page" do
    test "a postponed board says so, with the agreed date when there is one", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/2") |> doc()

      assert texts(document, "#board-2 .result .postponed") == [
               "Postponed, to be played 2026-03-20"
             ]

      assert texts(document, "#board-4 .result .postponed") == ["Postponed"]

      # Not also the "not yet reported" hyphen - the words replace it.
      assert texts(document, "#board-2 .result .unreported") == []
      assert texts(document, "#board-4 .result .unreported") == []
    end

    test "a played board is untouched", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/2") |> doc()

      assert texts(document, "#board-1 .result .token") == ["1/2-1/2"]
      assert texts(document, "#board-1 .result .postponed") == []
    end

    test "an unreported board that is not postponed keeps its hyphen", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/3") |> doc()

      assert texts(document, "#board-3 .result .unreported") == ["- not yet reported"]
      assert texts(document, "#board-3 .result .postponed") == []
    end

    test "the date follows the reader's language", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/2?lang=nl") |> doc()

      assert texts(document, "#board-2 .result .postponed") == [
               "Uitgesteld, te spelen op 20 maart 2026"
             ]

      assert texts(document, "#board-4 .result .postponed") == ["Uitgesteld"]
    end

    test "the date is left out when the arbiter hides dates", %{conn: conn, swiss: swiss} do
      publish(without_dates(swiss))
      document = conn |> get(~p"/t/#{@slug}/round/2") |> doc()

      assert texts(document, "#board-2 .result .postponed") == ["Postponed"]
    end

    test "the projector view says so too", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/round/2?display=1") |> doc()

      assert texts(document, "table.projector-pairings .result .postponed") == [
               "Postponed, to be played 2026-03-20",
               "Postponed"
             ]
    end

    test "once the game is played, the result takes the label's place", %{
      conn: conn,
      swiss: swiss
    } do
      played =
        update_in(swiss, ["rounds", Access.at(1), "boards", Access.at(1)], fn board ->
          board |> Map.drop(["postponed", "postponed_date"]) |> Map.put("result", "0-1")
        end)

      publish(played)
      document = conn |> get(~p"/t/#{@slug}/round/2") |> doc()

      assert texts(document, "#board-2 .result .token") == ["0-1"]
      assert texts(document, "#board-2 .result .postponed") == []
    end

    test "a later round's 'points before this round' column does not guess a postponed game",
         %{conn: conn, swiss: swiss} do
      # Round 3, board 1: player 3 was one seat of round 2's postponed board
      # 2. These standings stop after round 5, so nothing published prices
      # that game, and OpenPairings may count it as a win, a loss or nothing
      # as well as a draw. The column says it cannot be known.
      publish(standings_after(swiss, 5, %{}))
      document = conn |> get(~p"/t/#{@slug}/round/3") |> doc()

      assert texts(document, "#board-1 td:nth-child(7) .unreported") == [
               "- an earlier round is not public"
             ]

      # Board 3: player 8 was the other postponed board's White.
      assert texts(document, "#board-3 td:nth-child(3) .unreported") == [
               "- an earlier round is not public"
             ]
    end

    test "with standings that stop before the round, the column shows OpenPairings' own totals",
         %{conn: conn, swiss: swiss} do
      # 3-1-0 scoring, and the postponed game valued as the arbiter's rules
      # say: 3 drew round 1 (1) and the postponed game counts as a win for
      # 3 (3) - a total no 1/half/0 sum of the tokens could reach.
      publish(
        standings_after(swiss, 2, %{1 => 4, 2 => 4, 3 => 4, 6 => 0, 8 => 2, 9 => 3, 4 => 3})
      )

      document = conn |> get(~p"/t/#{@slug}/round/3") |> doc()

      assert texts(document, "#board-1 td:nth-child(7)") == ["4"]
      assert texts(document, "#board-3 td:nth-child(3)") == ["2"]
      assert texts(document, "#board-3 td:nth-child(3) .unreported") == []
    end

    test "the standings page is still flagged provisional beside those totals", %{
      conn: conn,
      swiss: swiss
    } do
      publish(standings_after(swiss, 2, %{1 => 1}))
      document = conn |> get(~p"/t/#{@slug}") |> doc()

      assert texts(document, "#standings-provisional") == [
               "Provisional: 2 postponed games are still to be played and count as draws until they are."
             ]
    end
  end

  describe "a player's card" do
    test "the round with the postponed game says so, with its date", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/player/6") |> doc()

      assert texts(document, "table.card tbody tr:nth-child(2) .result .postponed") == [
               "Postponed, to be played 2026-03-20"
             ]
    end

    test "without an agreed date it says only that", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}/player/8") |> doc()

      assert texts(document, "table.card tbody tr:nth-child(2) .result .postponed") == [
               "Postponed"
             ]
    end

    test "the running score stops there, as it does at any game with no result", %{
      swiss: swiss
    } do
      [round1, round2] = Tournament.card(swiss, 6)

      assert round1.score == 0.0
      assert round2.postponed
      assert round2.postponed_date == "2026-03-20"
      assert is_nil(round2.points)
      assert is_nil(round2.score)
    end
  end

  describe "the standings" do
    test "say they are provisional, and how many games are postponed", %{conn: conn} do
      document = conn |> get(~p"/t/#{@slug}") |> doc()

      assert texts(document, "#standings-provisional") == [
               "Provisional: 2 postponed games are still to be played and count as draws until they are."
             ]
    end

    test "say nothing of the kind when they are final", %{conn: conn} do
      publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{SnapshotPayloads.swiss()["tournament"]["slug"]}") |> doc()

      assert texts(document, "#standings-provisional") == []
    end
  end

  describe "team matches" do
    test "a match with a postponed board says its score is pending", %{conn: conn} do
      document = conn |> get(~p"/t/#{@team_slug}/round/1") |> doc()

      assert texts(document, "table.matches .match-pending") == [", 1 board pending"]
      # The provisional score and match points are still the ones that arrived.
      assert texts(document, "table.matches > tbody > tr:first-child td.num") |> hd() =~
               "1.5 - 0.5, 1 board pending (2-0 MP)"
    end

    test "its board line says the game is postponed", %{conn: conn} do
      document = conn |> get(~p"/t/#{@team_slug}/round/1") |> doc()

      assert texts(document, "table.pairings.nested .result .postponed") == ["Postponed"]
    end

    test "the team page marks the same match", %{conn: conn} do
      document = conn |> get(~p"/t/#{@team_slug}/team/1") |> doc()

      assert texts(document, ".match-pending") == [", 1 board pending"]
    end

    test "a match without postponed boards reads as before", %{conn: conn} do
      document = conn |> get(~p"/t/#{@team_slug}/team/2") |> doc()

      assert texts(document, ".match-pending") == []
    end

    test "the team cross-table marks the same match, in the cell rather than a page-level line",
         %{conn: conn} do
      document = conn |> get(~p"/t/#{@team_slug}") |> doc()

      # Team 1 v team 4 (match 1) is the postponed one; team 2 v team 3
      # (match 2) has nothing pending. Both sides of the postponed match
      # carry the mark - the row a reader is on decides which score it sits
      # beside, exactly as `crosstable_cell/1` decides which seat's score a
      # game belongs to.
      assert length(texts(document, "table.crosstable tbody .xt-postponed")) == 2

      assert texts(document, "table.crosstable tbody tr:first-child .xt-postponed") == [
               "⏳ 1 board pending"
             ]

      assert attributes(
               document,
               "table.crosstable tbody tr:first-child .xt-postponed",
               "title"
             ) == ["1 board pending"]
    end
  end

  describe "Tournament" do
    test "postponed?/1 reads only a literal true on a board with no result" do
      assert Tournament.postponed?(%{"postponed" => true, "result" => nil})
      refute Tournament.postponed?(%{"postponed" => true, "result" => "1-0"})
      refute Tournament.postponed?(%{"postponed" => "yes", "result" => nil})
      refute Tournament.postponed?(%{"result" => nil})
      refute Tournament.postponed?(nil)
    end

    test "postponed_date/1 only for a postponed board" do
      assert Tournament.postponed_date(%{"postponed" => true, "postponed_date" => "2026-03-20"}) ==
               "2026-03-20"

      assert Tournament.postponed_date(%{"postponed" => true}) == nil

      assert Tournament.postponed_date(%{"postponed_date" => "2026-03-20", "result" => "1-0"}) ==
               nil
    end

    test "a round waiting only on postponed games is not live", %{swiss: swiss} do
      refute Tournament.live_round?(Tournament.round(swiss, 2))

      # The fixture's round 3 still has an ordinary unreported board.
      assert Tournament.live_round?(Tournament.round(swiss, 3))
    end

    test "match_postponed_boards/1 and standings_provisional/1 read absence as none", %{
      swiss: swiss
    } do
      assert Tournament.match_postponed_boards(%{"postponed_boards" => 2}) == 2
      assert Tournament.match_postponed_boards(%{}) == 0
      assert Tournament.match_postponed_boards(%{"postponed_boards" => "2"}) == 0

      assert Tournament.standings_provisional(swiss) == {true, 2}
      assert Tournament.standings_provisional(SnapshotPayloads.swiss()) == {false, nil}
    end

    test "scores_before/2 never prices a postponed game from its token", %{swiss: swiss} do
      # Standings that stop after round 5 cover nothing before round 3, so
      # nothing published prices round 2's postponed boards (6 v 3, 8 v 9).
      before_round_3 = Tournament.scores_before(standings_after(swiss, 5, %{}), 3)

      for no <- [3, 6, 8, 9], do: assert(is_nil(before_round_3[no]))

      # Everyone else's total is untouched: player 1 won round 1 and drew
      # round 2, player 4 lost round 1 by forfeit and had round 2's bye.
      assert before_round_3[1] == 1.5
      assert before_round_3[4] == 1.0

      # A player's own card stops at the postponed game, as it always did.
      [_round1, round2] = Tournament.card(swiss, 6)
      assert is_nil(round2.score)
    end

    # What each valuation leaves players 6 and 3 (round 2's board 2, after a
    # lost and a drawn round 1) and 8 and 9 (board 4) with in a 1/half/0
    # tournament, as OpenPairings would publish it in `standings.rows`.
    @valuations [
      draw: %{6 => 0.5, 3 => 1.0, 8 => 1.0, 9 => 1.5},
      win_for_white: %{6 => 1.0, 3 => 0.5, 8 => 1.5, 9 => 1.0},
      loss_for_white: %{6 => 0.0, 3 => 1.5, 8 => 0.5, 9 => 2.0},
      nothing: %{6 => 0.0, 3 => 0.5, 8 => 0.5, 9 => 1.0}
    ]

    for {valuation, totals} <- @valuations do
      test "scores_before/2 reports the published total when a postponed game is valued as #{valuation}",
           %{swiss: swiss} do
        payload = standings_after(swiss, 2, unquote(Macro.escape(totals)))
        scores = Tournament.scores_before(payload, 3)

        for {no, points} <- unquote(Macro.escape(totals)), do: assert(scores[no] == points)
      end
    end

    test "scores_before/2 follows a 3-1-0 point system through the standings", %{swiss: swiss} do
      published = %{6 => 0, 3 => 1, 8 => 1, 9 => 4}
      scores = Tournament.scores_before(standings_after(swiss, 2, published), 3)

      assert scores[6] == 0.0
      assert scores[3] == 1.0
      assert scores[9] == 4.0

      # After the anchor, rounds are added up from their tokens again: player 6
      # takes round 3's half-point bye on top of the published total.
      assert Tournament.scores_before(standings_after(swiss, 2, published), 4)[6] == 0.5
    end

    test "scores_before/2 adds only the rounds after the standings, and stops at unknowns", %{
      swiss: swiss
    } do
      payload = standings_after(swiss, 2, %{1 => 2, 2 => 1, 3 => 2, 6 => 1, 8 => 1, 9 => 2})
      scores = Tournament.scores_before(payload, 4)

      # Round 3: player 1 beat 3 (1-0), player 4 drew a 1/2-0 against 2 (0.5
      # to 4), 8 v 5 has no result yet, player 6 had a half-point bye.
      assert scores[1] == 3.0
      assert scores[3] == 2.0
      assert scores[6] == 1.5
      assert is_nil(scores[8])
      assert is_nil(scores[5])
      # Player 4 is not in the standings rows, so their total is summed from
      # round 1 as before: a forfeit loss (0), the round 2 bye (1) and the
      # half point White took from 1/2-0 in round 3.
      assert scores[4] == 1.5
    end

    test "a postponed game in a round after the standings stays unknown", %{swiss: swiss} do
      payload = standings_after(swiss, 1, %{1 => 1, 2 => 0, 3 => 0.5, 6 => 0, 8 => 0.5, 9 => 1})
      scores = Tournament.scores_before(payload, 3)

      for no <- [3, 6, 8, 9], do: assert(is_nil(scores[no]))
      assert scores[1] == 1.5
    end
  end
end
