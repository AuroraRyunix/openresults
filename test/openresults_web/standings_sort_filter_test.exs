defmodule OpenResultsWeb.StandingsSortFilterTest do
  @moduledoc """
  Sorting and filtering the standings table, entirely in the browser.

  Everything the script needs is asserted here as markup: the data
  attributes it reads, the filter options it offers, and the one property
  that makes doing this client-side safe - the server's own HTML never
  varies with the query string a filter link might carry.

  The sort and the filter script itself is not run here - ExUnit renders no
  JavaScript - so what this file proves is the contract the script depends
  on, the same way `revalidate_test.exs` proves the ETag contract without
  running a browser's cache.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots}

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp hiding(payload, keys) do
    display = Map.new(keys, &{&1, false})
    put_in(payload, ["tournament", "display"], display)
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp attr(elements, name) do
    elements |> LazyHTML.attribute(name) |> Enum.reject(&is_nil/1)
  end

  describe "the data a sort or filter reads" do
    setup %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, document: get(conn, ~p"/t/#{slug}") |> doc(), slug: slug}
    end

    test "every row carries rank, name and points", %{document: document} do
      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      assert Enum.count(rows) == 10

      assert Enum.count(attr(rows, "data-rank")) == 10
      # Rank order, not pairing-number order - the fixture's own standings
      # order, exactly as `standings_table/1` renders it. Never re-sorted by
      # this app; see its moduledoc for why.
      assert attr(rows, "data-name") == Enum.map([9, 2, 1, 3, 4, 7, 5, 8, 6, 10], &player_name/1)
      assert Enum.count(attr(rows, "data-points")) == 10
    end

    test "a row carries its rating, which arrives as a number", %{document: document} do
      # The Rating column's sort button reads `data-rating`. Ratings arrive in
      # the snapshot as integers, and `data_value/1` used to pass only
      # strings, so the attribute was never written and the button reordered
      # nothing. No test asserted the attribute, so none saw it; found by
      # clicking the button in a browser.
      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      ratings = attr(rows, "data-rating")

      assert ratings != []
      assert Enum.all?(ratings, &(&1 =~ ~r/^\d+$/))
    end

    test "each tiebreak cell carries its own raw value", %{document: document} do
      first = document |> LazyHTML.query("table.standings > tbody > tr") |> Enum.at(0)
      cells = LazyHTML.query(first, "td.tb-cell")

      assert Enum.count(cells) == 4
      assert attr(cells, "data-value") == ["1.0", "1.5", "1.5", "3.0"]
    end

    test "every sortable column header carries its key, in column order", %{document: document} do
      buttons = LazyHTML.query(document, "table.standings thead button[data-sort-key]")
      keys = attr(buttons, "data-sort-key")

      assert keys == ["rank", "name", "rating", "category", "points", "tb0", "tb1", "tb2", "tb3"]
    end

    test "the whole table renders with no row marked hidden - JS off is the default", %{
      document: document
    } do
      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      refute Enum.any?(attr(rows, "hidden"))
    end

    test "the club, federation and category filters are all offered", %{document: document} do
      # Each list is "All ..." plus the distinct values: 9 clubs (one player
      # carries none), 9 federations (BEL appears twice), 2 categories.
      assert document |> LazyHTML.query(~s([data-filter="club"] option)) |> Enum.count() == 10

      assert document |> LazyHTML.query(~s([data-filter="federation"] option)) |> Enum.count() ==
               10

      assert document |> LazyHTML.query(~s([data-filter="category"] option)) |> Enum.count() == 3
    end

    test "the count element carries a translatable, placeholder template", %{document: document} do
      count = document |> LazyHTML.query("[data-standings-count]") |> Enum.at(0)
      assert attr(count, "data-count-label") == ["Showing {shown} of {total}"]
    end
  end

  defp player_name(1), do: "Müller, Jörg"
  defp player_name(2), do: "Đurić, Nikola"
  defp player_name(3), do: "Ó Súilleabháin, Séamus"
  defp player_name(4), do: "Łukasiewicz, Paweł"
  defp player_name(5), do: "Vandenberghe, Françoise"
  defp player_name(6), do: "Ștefănescu, Ioana"
  defp player_name(7), do: "Ångström, Åsa"
  defp player_name(8), do: "Björnsson, Sævar"
  defp player_name(9), do: "De Smet, Jean-Baptiste"
  defp player_name(10), do: "Nguyễn, Thị Hà"

  describe "the display-rule leak case" do
    test "hiding the club column takes the filter and the data with it", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> hiding(["club"]) |> publish()
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert document |> LazyHTML.query(~s([data-filter="club"])) |> Enum.empty?()
      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      refute Enum.any?(attr(rows, "data-club"))
    end

    test "hiding federation and rating does the same for each", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> hiding(["federation", "rating"]) |> publish()
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert document |> LazyHTML.query(~s([data-filter="federation"])) |> Enum.empty?()
      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      refute Enum.any?(attr(rows, "data-federation"))
      refute Enum.any?(attr(rows, "data-rating"))
      assert document |> LazyHTML.query(~s(thead button[data-sort-key="rating"])) |> Enum.empty?()
    end

    test "hiding the tiebreak columns leaves no tb-cell and no tb sort key", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> hiding(["tiebreaks"]) |> publish()
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert document |> LazyHTML.query("td.tb-cell") |> Enum.empty?()
      assert document |> LazyHTML.query(~s(thead button[data-sort-key^="tb"])) |> Enum.empty?()
    end

    test "a tournament with everything on shows every filter, as the control", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}") |> doc()

      refute document |> LazyHTML.query(~s([data-filter="club"])) |> Enum.empty?()
      refute document |> LazyHTML.query(~s([data-filter="federation"])) |> Enum.empty?()
    end
  end

  describe "a value that does not vary is not offered as a filter" do
    test "one club among every player is not a control" do
      one_club =
        SnapshotPayloads.swiss()
        |> update_in(["players", Access.all()], &Map.put(&1, "club", "Same Club"))
        |> put_in(["tournament", "slug"], "one-club")

      {:ok, _} = Snapshots.ingest(one_club)

      document = build_conn() |> get(~p"/t/one-club") |> doc()
      assert document |> LazyHTML.query(~s([data-filter="club"])) |> Enum.empty?()
    end
  end

  describe "the Keizer table" do
    test "rows carry value and score, and no tiebreak cells", %{conn: conn} do
      slug = publish(SnapshotPayloads.keizer())
      document = conn |> get(~p"/t/#{slug}") |> doc()

      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      row_count = Enum.count(rows)
      assert Enum.count(attr(rows, "data-value")) == row_count
      assert Enum.count(attr(rows, "data-score")) == row_count
      assert document |> LazyHTML.query("td.tb-cell") |> Enum.empty?()

      keys = document |> LazyHTML.query("thead button[data-sort-key]") |> attr("data-sort-key")
      assert "value" in keys
      assert "score" in keys
      assert Enum.all?(keys, &(not String.starts_with?(&1, "tb")))
    end
  end

  describe "the cache" do
    # The standings panel itself - the table a sort or filter script acts on
    # - rather than the whole document. `og:url` and the language picker's
    # own links both legitimately embed the current query string (see
    # `OpenResultsWeb.Layouts.canonical_url/1` and
    # `OpenResultsWeb.LocaleTest`'s "keeps the parameters the page already
    # had"), which is correct and has nothing to do with what this test is
    # about: whether the DATA the page shows depends on the query string.
    defp standings_panel(html) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-standings-panel]")
      |> LazyHTML.to_html()
    end

    test "a filter query string changes nothing about the standings themselves", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      plain = conn |> get(~p"/t/#{slug}") |> html_response(200)
      filtered = build_conn() |> get(~p"/t/#{slug}?club=SF+Berlin") |> html_response(200)

      # The whole point of doing this client-side: the server never looked at
      # the query string to decide what the standings show, so there is
      # nothing here for two different filter links to disagree about. The
      # documents differ elsewhere (their own self-referential links), which
      # is correct and is not what this asserts.
      assert standings_panel(plain) == standings_panel(filtered)
      refute plain == filtered
    end

    test "two readers of the same filtered link still get identical bytes", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      first = conn |> get(~p"/t/#{slug}?federation=BEL") |> html_response(200)
      second = build_conn() |> get(~p"/t/#{slug}?federation=BEL") |> html_response(200)

      assert first == second
    end

    test "a different query string still earns its own ETag", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      plain = get(conn, ~p"/t/#{slug}")
      filtered = get(build_conn(), ~p"/t/#{slug}?club=SF+Berlin")

      # Bytes are identical (asserted above); the validator still differs,
      # because `Revalidate` keys it off the request path AND query string -
      # see its own moduledoc. Two distinct entries holding the same body
      # costs a little cache space and buys nothing here, but it is what
      # keeps that plug's one rule simple: it never has to know which query
      # strings this particular page happens to ignore.
      refute get_resp_header(plain, "etag") == get_resp_header(filtered, "etag")
    end
  end
end
