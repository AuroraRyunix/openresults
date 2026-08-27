defmodule OpenResultsWeb.TournamentTest do
  use ExUnit.Case, async: true

  alias OpenResults.SnapshotPayloads
  alias OpenResultsWeb.Tournament

  setup do
    {:ok, swiss: SnapshotPayloads.swiss(), keizer: SnapshotPayloads.keizer()}
  end

  describe "result tokens" do
    test "every token the contract lists is read, and none other" do
      # The table in docs/snapshot-schema.md, copied out by hand so a token
      # quietly dropped from the module shows up here rather than as a player
      # card whose score stops for no visible reason.
      assert Tournament.result_points("1-0") == {1.0, 0.0}
      assert Tournament.result_points("0-1") == {0.0, 1.0}
      assert Tournament.result_points("1/2-1/2") == {0.5, 0.5}
      assert Tournament.result_points("1-0U") == {1.0, 0.0}
      assert Tournament.result_points("0-1U") == {0.0, 1.0}
      assert Tournament.result_points("1/2-1/2U") == {0.5, 0.5}
      assert Tournament.result_points("1/2-0") == {0.5, 0.0}
      assert Tournament.result_points("0-1/2") == {0.0, 0.5}
      assert Tournament.result_points("0-0") == {0.0, 0.0}
      assert Tournament.result_points("1-0FF") == {1.0, 0.0}
      assert Tournament.result_points("0-1FF") == {0.0, 1.0}
      assert Tournament.result_points("0-0FF") == {0.0, 0.0}
    end

    test "the legacy spellings are not accepted, because the publish path normalises them" do
      assert Tournament.result_points("+--") == nil
      assert Tournament.result_points("--+") == nil
    end

    test "an unreported game has no points" do
      assert Tournament.result_points(nil) == nil
    end

    test "forfeits and unrated games are annotated, ordinary ones are not" do
      assert Tournament.result_parts("1-0") == {"1-0", nil}
      assert Tournament.result_parts("1/2-1/2") == {"1/2-1/2", nil}
      assert Tournament.result_parts("1-0FF") == {"1-0", "forfeit"}
      assert Tournament.result_parts("0-0FF") == {"0-0", "forfeit"}
      assert Tournament.result_parts("0-1U") == {"0-1", "unrated"}
      assert Tournament.result_parts("1/2-1/2U") == {"1/2-1/2", "unrated"}
    end

    test "a token from a newer client survives verbatim rather than being guessed at" do
      assert Tournament.result_parts("1-0ADJ") == {"1-0ADJ", nil}
      assert Tournament.result_parts("2-0") == {"2-0", nil}
    end
  end

  describe "rounds" do
    test "only published rounds are present", %{swiss: swiss} do
      assert Tournament.round_numbers(swiss) == [1, 2, 3, 5]
      assert Tournament.round(swiss, 4) == nil
      assert Tournament.round(swiss, 3)["number"] == 3
    end

    test "the round strip covers the withheld round too", %{swiss: swiss} do
      assert Tournament.round_slots(swiss) == [1, 2, 3, 4, 5]
    end

    test "a round beyond the declared count still gets a slot", %{keizer: keizer} do
      extra = update_in(keizer, ["rounds"], &(&1 ++ [%{"number" => 9, "boards" => []}]))

      assert Tournament.rounds_count(extra) == 3
      assert Tournament.round_slots(extra) == [1, 2, 3, 9]
    end
  end

  describe "standings" do
    test "rows come back in the order they arrived", %{swiss: swiss} do
      shuffled = update_in(swiss, ["standings", "rows"], &Enum.reverse/1)

      assert Enum.map(Tournament.standings_rows(shuffled), & &1["rank"]) ==
               [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
    end

    test "tiebreak columns are whatever the payload declared", %{swiss: swiss} do
      assert Enum.map(Tournament.tiebreaks(swiss), &Tournament.tiebreak_label/1) ==
               ["Buchholz Cut-1", "Buchholz", "Sonneborn-Berger", "Progressive score"]
    end

    test "a tiebreak with no label falls back to its code" do
      assert Tournament.tiebreak_label(%{"code" => "ARO"}) == "ARO"
    end

    test "row values are read positionally and short rows blank out", %{swiss: swiss} do
      row = hd(Tournament.standings_rows(swiss))

      assert Tournament.tiebreak_value(row, 0) == 3.0
      assert Tournament.tiebreak_value(row, 3) == 5.0
      assert Tournament.tiebreak_value(row, 4) == nil
    end
  end

  describe "the player card" do
    test "colour, opponent and result come straight off the board", %{swiss: swiss} do
      [round_one | _rest] = Tournament.card(swiss, 1)

      assert round_one.kind == :game
      assert round_one.colour == :white
      assert round_one.opponent_no == 6
      assert round_one.opponent["name"] == "Ștefănescu, Ioana"
      assert round_one.result == "1-0"
    end

    test "a bye carries the arbiter's own value", %{swiss: swiss} do
      entry = Enum.at(Tournament.card(swiss, 4), 1)

      assert entry.kind == :bye
      assert entry.bye == "pairing-allocated"
      assert entry.points == 1.0
    end

    test "where the running score is knowable it agrees with the arbiter", %{swiss: swiss} do
      # Not an assertion the app makes anywhere - it never checks the arbiter.
      # It is here because a decoding table with a seat the wrong way round
      # would still look plausible on the page, and this is what catches it.
      #
      # Only the players whose every round is public are checked. Four of this
      # fixture's ten are correctly unknown after round 3: two are missing
      # from the round entirely and two are on the board whose result has not
      # been reported.
      after_round = swiss["standings"]["after_round"]

      checked =
        for row <- swiss["standings"]["rows"],
            entry = Enum.at(Tournament.card(swiss, row["player"]), after_round - 1),
            entry.score != nil do
          assert entry.score == row["points"],
                 "player #{row["player"]} scored #{inspect(entry.score)} after round " <>
                   "#{after_round}, standings say #{row["points"]}"

          row["player"]
        end

      assert length(checked) == 6
    end

    test "a withheld board leaves the arbiter's total the only one there is", %{swiss: swiss} do
      # Round 3 is published with three boards and two byes, which accounts
      # for eight of ten players. Players 7 and 10 played a board the arbiter
      # did not publish, so the page can show their standing but not derive
      # their total - and it says so rather than guessing.
      for no <- [7, 10] do
        entry = Enum.at(Tournament.card(swiss, no), 2)

        assert entry.kind == :no_game
        assert entry.score == nil
      end

      assert Enum.find(swiss["standings"]["rows"], &(&1["player"] == 7))["points"] == 1.0
    end

    test "the running score stops at a round the arbiter withheld", %{swiss: swiss} do
      card = Tournament.card(swiss, 1)

      assert Enum.map(card, & &1.score) == [1.0, 1.5, 2.5, nil, nil]
      assert Enum.at(card, 3).kind == :unpublished
      # Round 5 is published and its game is shown; only the total is unknown.
      assert Enum.at(card, 4).kind == :game
    end

    test "the running score stops at a game with no result yet", %{swiss: swiss} do
      # Board 3 of round 3 has a null result, so player 8's total is unknown
      # from there even though every round is published.
      card = Tournament.card(swiss, 8)

      assert Enum.at(card, 2).result == nil
      assert Enum.map(card, & &1.score) == [0.5, 0.5, nil, nil, nil]
    end

    test "a player absent from a published round is said to have no game published" do
      payload =
        SnapshotPayloads.swiss()
        |> update_in(["rounds", Access.at(0), "boards"], &Enum.drop(&1, 1))

      card = Tournament.card(payload, 1)

      assert hd(card).kind == :no_game
      assert hd(card).score == nil
    end

    test "every round of the tournament gets a row", %{swiss: swiss} do
      assert Enum.map(Tournament.card(swiss, 10), & &1.round) == [1, 2, 3, 4, 5]
    end
  end

  describe "tolerance" do
    test "keizer is keyed off system, not off which keys a row happens to have", %{
      swiss: swiss,
      keizer: keizer
    } do
      assert Tournament.keizer?(keizer)
      refute Tournament.keizer?(swiss)
    end

    test "a payload from a newer client reads exactly as it did before", %{swiss: swiss} do
      future = SnapshotPayloads.from_the_future(swiss)

      assert Tournament.name(future) == Tournament.name(swiss)
      assert Tournament.round_slots(future) == Tournament.round_slots(swiss)
      assert Tournament.card(future, 1) == Tournament.card(swiss, 1)
    end

    test "an older client that has not sent standings yet is not an error", %{swiss: swiss} do
      early = Map.delete(swiss, "standings")

      assert Tournament.standings_rows(early) == []
      assert Tournament.tiebreaks(early) == []
    end

    test "a key of the wrong shape costs that key and nothing else" do
      assert Tournament.name(%{"tournament" => "not an object"}) == "Tournament"
      assert Tournament.rounds(%{"rounds" => "not a list"}) == []
      assert Tournament.players(%{"players" => nil}) == []
      assert Tournament.round_slots(%{}) == []
    end
  end
end
