defmodule OpenResultsWeb.PageWeightTest do
  @moduledoc """
  What a phone downloads and lays out for the biggest field this site
  carries.

  A thousand players, nine rounds, four tie-break columns
  (`OpenResults.BigSnapshot`). Measured as the HTML a reader's browser has to
  parse - raw bytes, the gzip the page cache sends
  (`OpenResultsWeb.Plugs.Revalidate`) and the element count, which is what a
  low-end phone pays for in layout and memory, and again on every update the
  refresher swaps in.

  The standings page was 11 MB and 221,000 elements before each row's
  tie-break working moved to the player's own page above a hundred rows
  (`TournamentHTML.standings_table/1`); the budgets below are set with room
  over what it is now, and far under what it was.

  `MEASURE=1 mix test test/openresults_web/page_weight_test.exs` prints the
  numbers.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{BigSnapshot, Snapshots}
  alias OpenResultsWeb.TournamentHTML

  setup do
    payload = BigSnapshot.swiss()
    {:ok, _} = Snapshots.ingest(payload)
    {:ok, slug: payload["tournament"]["slug"], payload: payload}
  end

  defp weigh(conn, path) do
    html = conn |> get(path) |> html_response(200)
    document = LazyHTML.from_document(html)
    elements = document |> LazyHTML.query("*") |> Enum.count()
    gzip = html |> :zlib.gzip() |> byte_size()
    measured = %{path: path, raw: byte_size(html), gzip: gzip, elements: elements}

    if System.get_env("MEASURE"), do: IO.inspect(measured, label: "page weight")

    Map.put(measured, :document, document)
  end

  describe "standings, a thousand players" do
    test "stays inside the phone budget", %{conn: conn, slug: slug} do
      page = weigh(conn, ~p"/t/#{slug}")

      assert page.raw < 1_200_000
      assert page.gzip < 80_000
      assert page.elements < 25_000
    end

    test "carries no per-round working, and says where it is instead", %{
      conn: conn,
      slug: slug
    } do
      %{document: document} = weigh(conn, ~p"/t/#{slug}")

      assert document |> LazyHTML.query("table.standings > tbody > tr") |> Enum.count() == 1000
      assert document |> LazyHTML.query("details.tb-detail") |> Enum.empty?()
      refute document |> LazyHTML.query("#working-elsewhere") |> Enum.empty?()
    end

    test "a search narrowing it to a few rows brings the working back inline", %{
      conn: conn,
      slug: slug,
      payload: payload
    } do
      name = payload["players"] |> hd() |> Map.fetch!("name")
      %{document: document} = weigh(conn, ~p"/t/#{slug}?#{[q: name]}")

      rows = document |> LazyHTML.query("table.standings > tbody > tr") |> Enum.count()
      assert rows in 1..TournamentHTML.inline_working_rows()
      refute document |> LazyHTML.query("details.tb-detail") |> Enum.empty?()
      assert document |> LazyHTML.query("#working-elsewhere") |> Enum.empty?()
    end
  end

  test "pairings, five hundred boards, stay inside the phone budget", %{conn: conn, slug: slug} do
    page = weigh(conn, ~p"/t/#{slug}/round/9")

    assert page.raw < 600_000
    assert page.elements < 12_000
  end

  test "cross-table and player page render for a thousand players", %{conn: conn, slug: slug} do
    assert weigh(conn, ~p"/t/#{slug}/crosstable").elements > 0
    assert weigh(conn, ~p"/t/#{slug}/player/1").elements > 0
  end
end
