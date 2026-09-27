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

  defp publish(payload), do: {:ok, _snapshot} = Snapshots.ingest(payload)

  defp doc(conn), do: LazyHTML.from_document(html_response(conn, 200))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
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
  end
end
