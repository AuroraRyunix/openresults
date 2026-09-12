defmodule OpenResultsWeb.LocaleFormattingTest do
  @moduledoc """
  Numbers and dates, rendered through a real page rather than called
  directly - `OpenResultsWeb.FormatTest` already covers the module's own
  edge cases.

  Written for the 2026-09-12 translations audit, findings 2 and 3: every
  score on the site used `Float.to_string/1`, which never writes a comma,
  and every date was the ISO string the snapshot carried, in every
  language. The fix is approved for `nl` and `fr` only - `en` is asserted
  here just as often as the other two, so a regression that widened it
  fails a test in this file rather than only being caught by eye.
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.Plugs.Revalidate.Page

  setup do
    Snapshots.clear_cache()
    Page.clear()

    on_exit(fn ->
      Snapshots.clear_cache()
      Page.clear()
    end)

    swiss = SnapshotPayloads.swiss()
    {:ok, _snapshot} = Snapshots.ingest(swiss)
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  defp attrs(document, selector, name) do
    document |> LazyHTML.query(selector) |> attr(name)
  end

  defp attr(elements, name) do
    elements |> LazyHTML.attribute(name) |> Enum.reject(&is_nil/1)
  end

  # A tiebreak cell's own visible number, ignoring the `<details>` working
  # table it may open into - the same reading `TournamentControllerTest`
  # uses, copied here because a comma has to be checked in exactly the text
  # a reader would see, never in the hidden working rows underneath it.
  defp cell_values(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(fn td ->
      case LazyHTML.query(td, "details > summary") |> Enum.to_list() do
        [] ->
          td |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")

        [summary] ->
          summary
          |> LazyHTML.text()
          |> String.trim()
          |> String.replace(~r/\s+/, " ")
          |> String.split(" ")
          |> hd()
      end
    end)
  end

  defp publish(payload) do
    {:ok, _snapshot} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  describe "numbers on the standings page" do
    # Player 1: 1.5 points, tiebreaks [1.5, 1.5, 0.75, 2.5] - the fixture's
    # own row 3 (standings order is [9, 2, 1, 3, 4, 7, 5, 8, 6, 10]), chosen
    # because it carries a genuine fraction rather than a whole number that
    # `number/1` would print with no decimal point at all.
    test "en shows the point, nl and fr show the comma", %{slug: slug} do
      for {lang, points, tiebreaks} <- [
            {"en", "1.5", ["1.5", "1.5", "0.75", "2.5"]},
            {"nl", "1,5", ["1,5", "1,5", "0,75", "2,5"]},
            {"fr", "1,5", ["1,5", "1,5", "0,75", "2,5"]}
          ] do
        document = build_conn() |> get(~p"/t/#{slug}?lang=#{lang}") |> doc()
        row = "table.standings > tbody > tr:nth-child(3)"

        assert texts(document, "#{row} td.num.strong") == [points], "locale #{lang}"
        assert cell_values(document, "#{row} td.tb-cell") == tiebreaks, "locale #{lang}"
      end
    end

    test "ratings and ranks never gain a comma, in any locale", %{slug: slug} do
      # Carlsen-style four-digit ratings and pairing numbers are integers -
      # `number/1` never even sees them, but this is the guarantee the audit
      # asked for restated as a page-level assertion.
      for lang <- ~w(en nl fr) do
        html = build_conn() |> get(~p"/t/#{slug}?lang=#{lang}") |> html_response(200)
        refute html =~ ~r/\b\d,\d{3}\b/, "locale #{lang} grouped or comma-broke an integer"
      end
    end
  end

  describe "the data-* attributes a sort or filter reads" do
    test "stay dot-decimal in nl and fr exactly as they do in en", %{slug: slug} do
      for lang <- ~w(en nl fr) do
        document = build_conn() |> get(~p"/t/#{slug}?lang=#{lang}") |> doc()
        row = "table.standings > tbody > tr:nth-child(3)"

        assert attrs(document, row, "data-points") == ["1.5"], "locale #{lang}"

        assert attrs(document, "#{row} td.tb-cell", "data-value") ==
                 ["1.5", "1.5", "0.75", "2.5"],
               "locale #{lang}"
      end
    end

    test "the Keizer table's data-value and data-score stay dot-decimal too", %{conn: conn} do
      slug = publish(SnapshotPayloads.keizer())

      for lang <- ~w(en nl fr) do
        document = conn |> get(~p"/t/#{slug}?lang=#{lang}") |> doc()
        rows = LazyHTML.query(document, "table.standings > tbody > tr")

        assert attr(rows, "data-value") != []
        assert Enum.all?(attr(rows, "data-value"), &(not String.contains?(&1, ",")))
        assert Enum.all?(attr(rows, "data-score"), &(not String.contains?(&1, ",")))
      end
    end
  end

  describe "the cross-table" do
    test "a half-point score reads with a comma in nl and fr, a point in en", %{slug: slug} do
      swiss = through_last_round(SnapshotPayloads.swiss())
      publish(swiss)

      for {lang, expected} <- [{"en", "8 w 0.5"}, {"nl", "8 w 0,5"}, {"fr", "8 w 0,5"}] do
        document = build_conn() |> get(~p"/t/#{slug}/crosstable?lang=#{lang}") |> doc()
        cell = cell(document, 3, 1)
        assert cell == expected, "locale #{lang}"
      end
    end
  end

  describe "a player's placing and card" do
    test "follows the locale's own wording and number format", %{slug: slug} do
      for {lang, expected} <- [
            {"en", "of 10, on 1.5"},
            {"nl", "van 10, met 1,5"},
            {"fr", "sur 10, avec 1,5"}
          ] do
        document = build_conn() |> get(~p"/t/#{slug}/player/1?lang=#{lang}") |> doc()
        assert texts(document, ".placing-of") == [expected], "locale #{lang}"
      end
    end
  end

  describe "og:description" do
    test "carries the locale's own number format" do
      swiss = SnapshotPayloads.swiss()
      slug = swiss["tournament"]["slug"]

      for {lang, fragment} <- [{"en", "score 1.5"}, {"nl", "score 1,5"}, {"fr", "score 1,5"}] do
        document = build_conn() |> get(~p"/t/#{slug}/player/1?lang=#{lang}") |> doc()
        [description] = attrs(document, ~s|meta[name="description"]|, "content")
        assert description =~ fragment, "locale #{lang}: #{inspect(description)}"
      end
    end
  end

  describe "dates" do
    test "the masthead's range: an idiomatic span in nl and fr, ISO in en", %{slug: slug} do
      for {lang, expected} <- [
            {"en", "2026-03-01 to 2026-03-05"},
            {"nl", "1-5 maart 2026"},
            {"fr", "1-5 mars 2026"}
          ] do
        html = build_conn() |> get(~p"/t/#{slug}?lang=#{lang}") |> html_response(200)
        assert html =~ expected, "locale #{lang}"
      end
    end

    test "a round's own date, on the ordinary page and the projector", %{slug: slug} do
      for {lang, expected} <- [
            {"en", "2026-03-01"},
            {"nl", "1 maart 2026"},
            {"fr", "1 mars 2026"}
          ] do
        round = build_conn() |> get(~p"/t/#{slug}/round/1?lang=#{lang}") |> html_response(200)

        projector =
          build_conn() |> get(~p"/t/#{slug}/round/1?display=1&lang=#{lang}") |> html_response(200)

        assert round =~ expected, "round page, locale #{lang}"
        assert projector =~ expected, "projector, locale #{lang}"
      end
    end

    test "the entry form's start date follows the locale too", %{slug: slug} do
      for {lang, expected} <- [
            {"en", "starts 2026-03-01"},
            {"nl", "start 1 maart 2026"},
            {"fr", "début le 1 mars 2026"}
          ] do
        html = build_conn() |> get(~p"/t/#{slug}/register?lang=#{lang}") |> html_response(200)
        assert html =~ expected, "locale #{lang}"
      end
    end

    test "a range across two months names each one, and the year once" do
      payload =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "slug"], "cross-month-2026")
        |> put_in(["tournament", "start_date"], "2026-08-30")
        |> put_in(["tournament", "end_date"], "2026-09-02")

      publish(payload)

      for {lang, expected} <- [
            {"en", "2026-08-30 to 2026-09-02"},
            {"nl", "30 augustus - 2 september 2026"},
            {"fr", "30 août - 2 septembre 2026"}
          ] do
        html =
          build_conn() |> get(~p"/t/cross-month-2026?lang=#{lang}") |> html_response(200)

        assert html =~ expected, "locale #{lang}"
      end
    end

    test "a range across two years spells out the full date on both ends" do
      payload =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "slug"], "cross-year-2026")
        |> put_in(["tournament", "start_date"], "2026-12-30")
        |> put_in(["tournament", "end_date"], "2027-01-02")

      publish(payload)

      html = build_conn() |> get(~p"/t/cross-year-2026?lang=nl") |> html_response(200)
      assert html =~ "30 december 2026 - 2 januari 2027"
    end

    test "a malformed date never crashes the page, in nl or fr", %{swiss: swiss} do
      payload =
        swiss
        |> put_in(["tournament", "slug"], "malformed-date-2026")
        |> put_in(["tournament", "start_date"], "not-a-real-date")

      publish(payload)

      for lang <- ~w(nl fr) do
        html =
          build_conn() |> get(~p"/t/malformed-date-2026?lang=#{lang}") |> html_response(200)

        # Rendered as it arrived rather than crashing or vanishing - the
        # same thing this page would have shown before this module existed.
        assert html =~ "not-a-real-date"
      end
    end

    test "a missing date is omitted, exactly as it was before", %{swiss: swiss} do
      payload =
        swiss
        |> put_in(["tournament", "slug"], "no-dates-2026")
        |> update_in(["tournament"], &Map.drop(&1, ["start_date", "end_date"]))

      publish(payload)

      for lang <- ~w(en nl fr) do
        html =
          build_conn() |> get(~p"/t/no-dates-2026?lang=#{lang}") |> html_response(200)

        refute html =~ "2026-03-01"
      end
    end
  end

  defp through_last_round(payload) do
    last = payload["rounds"] |> Enum.map(& &1["number"]) |> Enum.max()
    put_in(payload, ["standings", "after_round"], last)
  end

  # Copied from `OpenResultsWeb.CrosstableTest`: player `no`'s cell for the
  # `index`-th PUBLISHED round (index 1 is round 1). Rows are in
  # starting-number order, so player `no` is row `no` in this fixture.
  @first_round 4

  defp cell(document, no, index) do
    document
    |> texts(
      "table.crosstable tbody tr:nth-child(#{no}) td:nth-child(#{@first_round + index - 1})"
    )
    |> List.first()
  end
end
