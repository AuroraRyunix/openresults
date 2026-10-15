defmodule OpenResultsWeb.PendingGamesTest do
  @moduledoc """
  Pending games, as a spectator sees them - `boards[].pending` and
  `standings.pending_games` in `docs/snapshot-schema.md`: a round-robin
  board nobody has entered, in a round the tournament has moved past, which
  OpenPairings' standings count until its result is in.

  The fixture is OpenPairings' own (`SnapshotPayloads.round_robin_pending/0`):
  round 2's board 3 (1 v 2) pending, round 3's board 1 (2 v 6) postponed,
  standings after round 4.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.Tournament

  setup do
    payload = SnapshotPayloads.round_robin_pending()
    {:ok, _} = Snapshots.ingest(payload)
    {:ok, payload: payload, slug: payload["tournament"]["slug"]}
  end

  defp doc(conn), do: LazyHTML.from_document(html_response(conn, 200))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  describe "reading the payload" do
    test "a pending board is outstanding and not postponed", %{payload: payload} do
      board = payload["rounds"] |> Enum.at(1) |> Map.fetch!("boards") |> Enum.at(2)

      assert Tournament.pending?(board)
      refute Tournament.postponed?(board)
      assert Tournament.outstanding?(board)
    end

    test "the count is every pending game, and some of them are not postponed",
         %{payload: payload} do
      assert Tournament.standings_provisional(payload) == {true, 2}
      assert Tournament.standings_unreported?(payload)
    end

    test "an older snapshot without pending_games still reads its postponed count",
         %{payload: payload} do
      older = update_in(payload, ["standings"], &Map.delete(&1, "pending_games"))

      assert Tournament.standings_provisional(older) == {true, 1}
      refute Tournament.standings_unreported?(older)
    end
  end

  describe "the standings" do
    test "say they are provisional, with the count, without calling every game postponed",
         %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert texts(document, "#standings-provisional") == [
               "Provisional: 2 games have no result yet and count as draws until they have."
             ]
    end

    test "in Dutch", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}?lang=nl") |> doc()

      assert texts(document, "#standings-provisional") == [
               "Voorlopig: 2 partijen hebben nog geen uitslag en tellen tot dan als remise."
             ]
    end
  end

  describe "the pending board" do
    test "a round's page says the result is not in yet, not that it was postponed",
         %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/2") |> doc()

      assert texts(document, "#board-3 .result .pending") == ["Result not yet in"]
      assert texts(document, "#board-3 .result .unreported") == []
    end

    test "the postponed board beside it keeps its own word", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/3") |> doc()

      assert texts(document, "#board-1 .result .postponed") == ["Postponed"]
      assert texts(document, "#board-1 .result .pending") == []
    end

    test "the blanks of the round being played are still plain blanks",
         %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/5") |> doc()

      assert texts(document, "#board-2 .result .pending") == []
      assert length(texts(document, "#board-2 .result .unreported")) == 1
    end

    test "the cross-table marks both seats of it", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/crosstable") |> doc()

      marks = texts(document, "table.crosstable tbody .xt-postponed")
      # Two seats of the pending game, two of the postponed one.
      assert length(marks) == 4
      assert Enum.count(marks, &String.contains?(&1, "Result not yet in")) == 2
    end
  end
end
