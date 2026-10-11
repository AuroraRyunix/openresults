defmodule OpenResultsWeb.UncountedRowsTest do
  @moduledoc """
  `standings.rows[].uncounted` - a round-robin player who left with fewer
  than half the games played (FIDE C.05 6.6). The results stay in the table
  and count for nobody; the row has no place. OpenPairings marks it, and
  this site's job is to stop printing it as "6th, on 2 points" under a
  player who has half a point.

  The fixture is OpenPairings' own (`snapshot_roundrobin_uncounted.json`):
  six players, number 6 withdrawn after two wins and three forfeits.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.{Hall, Meta, Tournament}
  alias OpenResultsWeb.Tournament.Filter

  @out 6

  defp payload, do: SnapshotPayloads.round_robin_uncounted()

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp row_html(html, class) do
    [_, rest] = String.split(html, ~s(<tr class="#{class}">), parts: 2)
    rest |> String.split("</tr>", parts: 2) |> hd()
  end

  describe "the fixture" do
    test "marks one row, the last, and nobody else" do
      rows = Tournament.standings_rows(payload())

      assert Enum.map(rows, &Tournament.uncounted?/1) == [false, false, false, false, false, true]
      assert List.last(rows)["player"] == @out
      assert Tournament.ranked_total(payload()) == 5
    end

    test "a payload without the key has nobody uncounted" do
      assert MapSet.size(Tournament.uncounted_players(SnapshotPayloads.swiss())) == 0

      assert Tournament.ranked_total(SnapshotPayloads.swiss()) ==
               length(Tournament.standings_rows(SnapshotPayloads.swiss()))
    end
  end

  describe "the standings page" do
    test "prints the row without a place, marked, with the footnote", %{conn: conn} do
      html = conn |> get(~p"/t/#{publish(payload())}") |> html_response(200)
      row = row_html(html, "uncounted")

      assert row =~ "Maes, Kobe"
      assert row =~ "results not counted (withdrawn)"
      assert row =~ ~r/<td class="num rank">\s*–/
      assert html =~ "FIDE C.05 6.6"
    end

    test "says nothing of it for a tournament without such a row", %{conn: conn} do
      html = conn |> get(~p"/t/#{publish(SnapshotPayloads.swiss())}") |> html_response(200)

      refute html =~ "results not counted"
      refute html =~ "C.05 6.6"
      refute html =~ ~s(class="uncounted")
    end

    test "in Dutch and in French", %{conn: conn} do
      slug = publish(payload())

      assert conn |> get(~p"/t/#{slug}?lang=nl") |> html_response(200) =~
               "resultaten tellen niet mee (teruggetrokken)"

      assert conn |> get(~p"/t/#{slug}?lang=fr") |> html_response(200) =~
               "résultats non comptabilisés (retrait)"
    end

    test "a category's places skip the row" do
      # Everybody in one category: the withdrawn player is not its sixth.
      payload =
        payload()
        |> update_in(["players"], fn players ->
          Enum.map(players, &Map.merge(&1, %{"category" => "A", "categories" => ["A"]}))
        end)
        |> put_in(["tournament", "categories"], ["A"])

      places = Filter.standings(payload, %OpenResultsWeb.FilterParams{category: "A"}).places

      assert map_size(places) == 5
      refute Map.has_key?(places, @out)
    end
  end

  describe "the cross-table" do
    test "keeps the games and drops the place", %{conn: conn} do
      html = conn |> get(~p"/t/#{publish(payload())}/crosstable") |> html_response(200)
      row = row_html(html, "uncounted")

      assert row =~ "Maes, Kobe"
      assert row =~ "results not counted (withdrawn)"
      assert row =~ ~r/<td class="num rank">\s*–/
      assert html =~ "FIDE C.05 6.6"

      table = Tournament.crosstable(payload())
      out = Enum.find(table, &(&1.no == @out))
      assert out.uncounted?
      assert out.rank == nil
      # The games are still there.
      assert Enum.count(out.cells, & &1) == 5
      refute Enum.any?(table, &(&1.no != @out and &1.uncounted?))
    end
  end

  describe "a player's card" do
    test "the withdrawn player's has no place", %{conn: conn} do
      html = conn |> get(~p"/t/#{publish(payload())}/player/#{@out}") |> html_response(200)

      assert html =~ "results not counted (withdrawn)"
      refute html =~ ~s(class="placing-rank")
    end

    test "an opponent's running score lands on their standings points" do
      payload = payload()

      for row <- Tournament.standings_rows(payload), not Tournament.uncounted?(row) do
        card = Tournament.card(payload, row["player"])

        assert List.last(card).score == row["points"]
        assert Enum.count(card, & &1.uncounted?) == 1
        assert Enum.find(card, & &1.uncounted?).opponent_no == @out
      end

      # The withdrawn player's own card is the record of what they did.
      own = Tournament.card(payload, @out)
      refute Enum.any?(own, & &1.uncounted?)
      assert List.last(own).score == 2.0
    end

    test "an opponent's card says which game is not counted", %{conn: conn} do
      html = conn |> get(~p"/t/#{publish(payload())}/player/1") |> html_response(200)

      assert html =~ "not counted"
      assert html =~ "of 5, on"
    end

    test "the scores into a round leave those games out too" do
      payload = payload()
      before_five = Tournament.scores_before(payload, 5)

      # Number 4 lost to the withdrawn player in round 2 and number 2 was
      # given a forfeit win in round 3: neither moves a score.
      assert before_five[2] == 2.0
      assert before_five[4] == 1.5
      assert before_five[@out] == 2.0
    end
  end

  describe "everywhere else a place is said" do
    test "the page description gives the withdrawn player no place" do
      payload = payload()
      out = Enum.find(payload["players"], &(&1["no"] == @out))
      first = Enum.find(payload["players"], &(&1["no"] == 2))

      refute Meta.player(payload, out) =~ "place"
      assert Meta.player(payload, first) =~ "place 1 of 5"
    end

    test "the hall display's standings list the ranked rows only" do
      payload = put_in(payload(), ["tournament", "hall", "standings_top"], 50)
      data = Hall.build(payload, Hall.settings(payload))

      ids = Enum.map(data.standings.rows, & &1.id)
      assert length(ids) == 5
      refute "standing-#{@out}" in ids
    end
  end
end
