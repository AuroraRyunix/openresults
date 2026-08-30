defmodule OpenResultsWeb.TiebreakWorkingTest do
  @moduledoc """
  The published working, and the two rules that make it worth showing:

    * the parts add up to the number beside them, and
    * this app never adds them up to check.

  The second is not a slogan. The contributions are opponents' Article 16
  ADJUSTED scores, which are not in the document, so anything computed here
  from what IS in the document would print a total that disagrees with the
  arbiter's - in front of the players.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.Tournament

  setup do
    swiss = SnapshotPayloads.swiss()
    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  describe "reading the contract" do
    test "every part list totals the tie-break beside it", %{swiss: swiss} do
      codes = swiss |> Tournament.tiebreaks() |> Enum.map(&Map.get(&1, "code"))

      for row <- Tournament.standings_rows(swiss) do
        working = Tournament.working(swiss, row["player"])

        for {code, %{"total" => total, "parts" => parts}} <- working do
          at = Enum.find_index(codes, &(&1 == code))
          assert total == Tournament.tiebreak_value(row, at)

          # And the parts the arbiter marked as counting are the ones that
          # reach it. Computed here ONLY to prove the contract holds - no
          # page does this.
          summed =
            parts
            |> Enum.filter(&Tournament.part_counted?/1)
            |> Enum.map(&Map.get(&1, "value"))
            |> Enum.sum()

          assert_in_delta summed, total, 0.001
        end
      end
    end

    test "a part with no kind is a counted one" do
      part = %{"round" => 1, "value" => 2.0}

      assert Tournament.part_kind(part) == "played"
      assert Tournament.part_counted?(part)
    end

    test "cut and excluded parts are published and do not count", %{swiss: swiss} do
      refute Tournament.part_counted?(%{"kind" => "cut", "value" => 3.0})
      refute Tournament.part_counted?(%{"kind" => "excluded", "value" => 0.0})
      assert Tournament.part_counted?(%{"kind" => "virtual", "value" => 1.5})

      # And at least one really is in the fixture, or the rest of this file
      # would be testing a shape nothing produces.
      kinds =
        for row <- Tournament.standings_rows(swiss),
            {_code, w} <- Tournament.working(swiss, row["player"]),
            part <- w["parts"],
            do: Tournament.part_kind(part)

      assert "cut" in kinds
      assert "virtual" in kinds
    end

    test "the codes read back in the arbiter's own column order", %{swiss: swiss} do
      no = Tournament.standings_rows(swiss) |> hd() |> Map.get("player")
      declared = swiss |> Tournament.tiebreaks() |> Enum.map(&Map.get(&1, "code"))

      codes = Tournament.working_codes(swiss, no)

      assert codes == Enum.filter(declared, &(&1 in codes))
    end

    test "a player with no standings row has no working", %{swiss: swiss} do
      assert Tournament.working(swiss, 9999) == %{}
      assert Tournament.working_codes(swiss, 9999) == []
    end

    test "a malformed working block reads as empty rather than raising" do
      payload = %{"standings" => %{"rows" => [%{"player" => 1, "working" => %{"BH" => "nope"}}]}}

      assert %{"BH" => %{"total" => nil, "parts" => []}} = Tournament.working(payload, 1)
    end
  end

  describe "the player page" do
    test "shows every contribution against the round it came from", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert texts(document, ".working h3") == ["Where the tie-breaks come from"]

      # Buchholz Cut-1 discarded round 1; the row is still there, marked.
      rows = texts(document, ".working-block:first-of-type .working-table tbody tr")
      assert Enum.any?(rows, &(&1 =~ "discarded"))

      assert Enum.any?(texts(document, ".working p.footnote"), &(&1 =~ "does not calculate"))
    end

    test "the summary says what each tie-break is made of", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      summary = texts(document, "#player-summary .tiebreak-summary tbody tr")

      assert Enum.any?(summary, &(&1 =~ "Buchholz Cut-1" and &1 =~ "discarded"))
      assert Enum.any?(summary, &(&1 =~ "from 3 rounds"))
    end

    test "the placing is the rank and the field size", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert texts(document, ".placing") == ["1 of 10, on 2.5"]
    end
  end

  describe "the two sections, which is why the two gestures now differ" do
    test "the summary carries the placing and offers the page", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      # The overlay lifts #player-summary out of this page. Everything it
      # needs has to be inside it, and the detail has to be outside it, or
      # right-click and left-click go back to showing the same thing.
      assert texts(document, "#player-summary .placing") != []
      assert texts(document, "#player-summary .tiebreak-summary") != []
      assert texts(document, "#player-summary .working") == []
      assert texts(document, "#player-summary table.card") == []
      assert texts(document, "#player-summary .chart") == []

      assert texts(document, "#player-summary .card-more") == ["Full card, round by round"]
    end

    test "the detail carries the chart, the rounds and the full working", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert texts(document, "#player-detail .chart figcaption") != []
      assert texts(document, "#player-detail table.card thead") != []
      assert texts(document, "#player-detail .working h3") != []
    end
  end

  describe "the chart" do
    test "draws a bar per contributing round and a line through the score", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert LazyHTML.query(document, ".chart-svg polyline.chart-line") |> Enum.count() == 1
      assert LazyHTML.query(document, ".chart-svg rect.chart-bar") |> Enum.count() >= 1

      # The discarded round is drawn, in the withheld colour, rather than
      # left out - "that round did not help you" is the interesting part.
      assert LazyHTML.query(document, ".chart-svg rect.chart-bar-out") |> Enum.count() == 1
    end

    test "a player with nothing to plot gets no figure", %{conn: conn, swiss: swiss} do
      # Not "a player on zero": player 10 finishes on nothing but played two
      # published rounds, so their opponents still make bars. The guard is
      # about having nothing to draw at all, which is a tournament whose
      # rounds have not been published yet.
      nothing =
        swiss
        |> put_in(["tournament", "slug"], "nothing-yet")
        |> Map.put("rounds", [])
        |> update_in(["standings", "rows"], fn rows ->
          Enum.map(rows, &Map.put(&1, "working", %{}))
        end)

      {:ok, _} = Snapshots.ingest(nothing)

      document = conn |> get(~p"/t/nothing-yet/player/10") |> doc()

      assert LazyHTML.query(document, ".chart-svg") |> Enum.count() == 0
      # And the page still renders rather than falling over on the gap.
      assert texts(document, "#player-summary .placing") != []
    end
  end

  describe "when the arbiter hides the tie-break columns" do
    test "there is no working to show, and the page says nothing about it", %{
      conn: conn,
      swiss: swiss
    } do
      hidden =
        put_in(swiss, ["tournament", "display", "tiebreaks"], false)
        |> put_in(["tournament", "slug"], "hidden-tiebreaks")
        |> strip_working()

      {:ok, _} = Snapshots.ingest(hidden)

      document = conn |> get(~p"/t/hidden-tiebreaks/player/1") |> doc()

      assert texts(document, ".working") == []
      assert texts(document, ".tiebreak-summary") == []
      # The placing itself is not a tie-break and stays.
      assert texts(document, ".placing") != []
    end
  end

  # What the publisher does when the columns are off: the working never
  # travels. Mirrored here so this test exercises the real shape rather than
  # a payload that still carries it.
  defp strip_working(payload) do
    update_in(payload, ["standings", "rows"], fn rows ->
      Enum.map(rows, &Map.put(&1, "working", %{}))
    end)
  end
end
