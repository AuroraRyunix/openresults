defmodule OpenResultsWeb.TournamentControllerTest do
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  setup do
    swiss = SnapshotPayloads.swiss()
    keizer = SnapshotPayloads.keizer()

    {:ok, _snapshot} = Snapshots.ingest(swiss)
    {:ok, _snapshot} = Snapshots.ingest(keizer)

    {:ok, swiss: swiss, keizer: keizer, slug: swiss["tournament"]["slug"]}
  end

  defp publish(payload), do: {:ok, _snapshot} = Snapshots.ingest(payload)

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  describe "GET /" do
    test "lists what has published", %{conn: conn, swiss: swiss} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ swiss["tournament"]["name"]
      assert html =~ ~s|href="/t/#{swiss["tournament"]["slug"]}"|
    end
  end

  describe "GET /t/:slug - standings" do
    test "renders the tournament and its placings", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert texts(document, "h1") == ["Gent Spring Open 2026"]
      assert texts(document, "td.rank") == ~w(1 2 3 4 5 6 7 8 9 10)
      assert texts(document, "h2") == ["Standings after round 3"]
    end

    test "the tiebreak columns are the payload's labels, in the payload's order", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert texts(document, "table.standings thead th") ==
               ["#", "Player", "Rating", "Points"] ++
                 ["Buchholz Cut-1", "Buchholz", "Sonneborn-Berger", "Progressive score"]
    end

    test "an arbiter with different tiebreaks gets different columns, with no code change", %{
      conn: conn,
      swiss: swiss
    } do
      # The whole point of the positional list: this app has never heard of
      # ARO and does not need to be taught.
      rebuilt =
        swiss
        |> put_in(["standings", "tiebreaks"], [%{"code" => "ARO", "label" => "Average rating"}])
        |> update_in(["standings", "rows"], fn rows ->
          Enum.map(rows, &Map.put(&1, "tiebreaks", [1997]))
        end)

      publish(rebuilt)
      document = conn |> get(~p"/t/#{rebuilt["tournament"]["slug"]}") |> doc()

      assert texts(document, "table.standings thead th") ==
               ["#", "Player", "Rating", "Points", "Average rating"]

      assert texts(document, "table.standings tbody tr:first-child td:last-child") == ["1997"]
    end

    test "a row with fewer values than there are columns leaves the cell blank", %{
      conn: conn,
      swiss: swiss
    } do
      short =
        update_in(swiss, ["standings", "rows", Access.at(0), "tiebreaks"], &Enum.take(&1, 2))

      publish(short)

      document = conn |> get(~p"/t/#{short["tournament"]["slug"]}") |> doc()

      assert texts(document, "table.standings tbody tr:first-child td") ==
               ["1", "GM Müller, Jörg 2601", "2601", "2.5", "3", "3.5", "", ""]
    end

    test "rows render in the order they arrived, not in the order this app would sort them", %{
      conn: conn,
      swiss: swiss
    } do
      # The arbiter is the authority. If their tenth-placed player arrives
      # first, that is what the page shows.
      reversed = update_in(swiss, ["standings", "rows"], &Enum.reverse/1)
      publish(reversed)

      document = conn |> get(~p"/t/#{reversed["tournament"]["slug"]}") |> doc()

      assert texts(document, "td.rank") == ~w(10 9 8 7 6 5 4 3 2 1)
    end

    test "keizer standings carry keizer's columns", %{conn: conn, keizer: keizer} do
      document = conn |> get(~p"/t/#{keizer["tournament"]["slug"]}") |> doc()

      assert texts(document, "table.standings thead th") ==
               ["#", "Player", "Rating", "Value", "Keizer points", "Score"]

      assert texts(document, "table.standings tbody tr:first-child td") ==
               ["1", "Peeters, Wouter 2088", "2088", "12", "17", "2"]
    end

    test "a player with no rating, title or club renders cleanly", %{conn: conn, slug: slug} do
      # Player 10 has none of the three. Club play is mostly missing fields.
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert texts(document, "table.standings tbody tr:last-child td") ==
               ["10", "Nguyễn, Thị Hà", "", "0", "2.5", "2.5", "0", "0"]
    end

    test "a tournament with no standings yet says so instead of showing an empty table", %{
      conn: conn,
      swiss: swiss
    } do
      publish(Map.delete(swiss, "standings"))

      html = conn |> get(~p"/t/#{swiss["tournament"]["slug"]}") |> html_response(200)

      assert html =~ "No standings have been published"
      refute html =~ "Buchholz"
    end

    test "a slug nobody has published is a 404", %{conn: conn} do
      html = conn |> get(~p"/t/no-such-tournament") |> html_response(404)

      assert html =~ "No tournament has published under no-such-tournament"
    end

    test "a payload from a newer client renders anyway", %{conn: conn, swiss: swiss} do
      publish(SnapshotPayloads.from_the_future(swiss))

      document = conn |> get(~p"/t/#{swiss["tournament"]["slug"]}") |> doc()

      assert texts(document, "td.rank") == ~w(1 2 3 4 5 6 7 8 9 10)
    end
  end

  describe "GET /t/:slug/round/:n - pairings" do
    test "renders board, white, result and black", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert texts(document, "h2") == ["Round 1 2026-03-01"]

      assert texts(document, "table.pairings tbody tr:first-child td") ==
               ["1", "Müller, Jörg", "1-0", "Ștefănescu, Ioana"]
    end

    test "a forfeit says it was not played and an unrated game says it will not count", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert texts(document, "table.pairings tbody tr:nth-child(4) td.num .result") ==
               ["1-0 forfeit"]

      assert texts(document, "table.pairings tbody tr:nth-child(5) td.num .result") ==
               ["1-0 unrated"]
    end

    test "a game with no result yet is a hyphen, not a blank", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/3") |> doc()

      assert texts(document, "table.pairings tbody tr:last-child td.num .result") == ["-"]
    end

    test "a result token this server has never seen is shown as it arrived", %{
      conn: conn,
      swiss: swiss
    } do
      invented =
        put_in(swiss, ["rounds", Access.at(0), "boards", Access.at(0), "result"], "1-0ADJ")

      publish(invented)

      document = conn |> get(~p"/t/#{invented["tournament"]["slug"]}/round/1") |> doc()

      assert texts(document, "table.pairings tbody tr:first-child td.num .result") == ["1-0ADJ"]
    end

    test "byes carry their kind and the arbiter's own value", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/2") |> doc()

      assert texts(document, "table.byes tbody tr") == [
               "Łukasiewicz, Paweł pairing-allocated bye 1",
               "Nguyễn, Thị Hà absent 0"
             ]
    end

    test "a round with no byes has no byes table", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert texts(document, "table.byes") == []
    end

    test "a round the arbiter withheld is a 404, not an empty page", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/round/4") |> html_response(404)

      assert html =~ "Round 4 of Gent Spring Open 2026 has not been published"
    end

    test "a round that does not exist at all is the same 404", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}/round/9") |> html_response(404)
      assert conn |> get(~p"/t/#{slug}/round/0") |> html_response(404)
    end

    test "a round number that is not a number is a 404, not a crash", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}/round/abc") |> html_response(404)
      assert conn |> get(~p"/t/#{slug}/round/3x") |> html_response(404)
    end

    test "the round strip shows the withheld round without linking it", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert texts(document, "nav.rounds a.chip") == ["Standings", "1", "2", "3", "5"]
      assert texts(document, "nav.rounds span.chip.withheld") == ["4, not published"]
    end
  end

  describe "GET /t/:slug/player/:no - the card" do
    test "one row per round, with colour, opponent, result and running score", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert texts(document, "table.card tbody tr") == [
               "1 White WIM Ștefănescu, Ioana 2033 1-0 1",
               "2 Black IM Đurić, Nikola 2455 1/2-1/2 1.5",
               "3 White FM Ó Súilleabháin, Séamus 2312 1-0 2.5",
               "4 not published",
               "5 Black IM Đurić, Nikola 2455 0-1"
             ]
    end

    test "the running score stops where the tournament stops being public", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert texts(document, "table.card tbody td.strong") == ["1", "1.5", "2.5", "", ""]

      assert conn |> get(~p"/t/#{slug}/player/1") |> html_response(200) =~
               "The running score stops at the first round"
    end

    test "a bye is a row of its own with the arbiter's value", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/player/4") |> doc()

      assert texts(document, "table.card tbody tr:nth-child(2)") ==
               ["2 pairing-allocated bye 1 1"]
    end

    test "a published round the player is missing from says only what is true", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/player/7") |> doc()

      assert texts(document, "table.card tbody tr:nth-child(3)") ==
               ["3 no game published for this round"]
    end

    test "a player with no title, rating or club renders cleanly", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/player/10") |> html_response(200)

      assert html =~ "Nguyễn, Thị Hà"
      assert html =~ "no. 10"
    end

    test "a player the tournament does not have is a 404", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/player/99") |> html_response(404)

      assert html =~ "has no player 99"
    end

    test "a pairing number that is not a number is a 404, not a crash", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}/player/abc") |> html_response(404)
    end
  end

  describe "the read path" do
    test "sets no cookie on any page", %{conn: conn, slug: slug} do
      # The proof that `fetch_session` is gone rather than merely unused. A
      # results page that sets nothing needs no consent banner and can be
      # cached by anything sitting in front of it.
      for path <- [
            ~p"/",
            ~p"/t/#{slug}",
            ~p"/t/#{slug}/round/1",
            ~p"/t/#{slug}/player/1",
            ~p"/t/#{slug}/round/4"
          ] do
        conn = get(conn, path)

        assert get_resp_header(conn, "set-cookie") == [], "#{path} set a cookie"
      end
    end

    test "needs no javascript to read a result", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/round/1") |> html_response(200)

      refute html =~ "<script"
      refute html =~ "csrf-token"
    end
  end
end
