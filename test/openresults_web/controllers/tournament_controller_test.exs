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

  # What OpenPairings sends before it has closed round one: every entered
  # player, no rounds, and `standings.after_round: 0` rather than an absent
  # field - see `Tournament.after_round/1`'s own doc for why 0 has to read
  # the same way absence does.
  defp no_rounds(payload) do
    payload
    |> Map.put("rounds", [])
    |> put_in(["standings", "after_round"], 0)
    |> put_in(["standings", "rows"], [])
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  # The plain value a standings cell shows, ignoring a tiebreak's own
  # explanatory detail - see `OpenResultsWeb.TournamentHTML.tiebreak_cell/1`.
  # `LazyHTML.text/1` reads every descendant regardless of whether
  # `<details>` is open, because that is what static HTML text always is;
  # what a reader actually SEES collapsed is only the `<summary>`'s own
  # leading word, which is what this returns instead.
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
      assert texts(document, "h2") == ["Standings after round 2"]
    end

    test "the tiebreak columns are the payload's labels, in the payload's order", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert texts(document, "table.standings thead th") ==
               ["#", "Player", "Rating", "Cat", "Points"] ++
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
               ["#", "Player", "Rating", "Cat", "Points", "Average rating"]

      assert texts(document, "table.standings > tbody > tr:first-child > td:last-child") ==
               ["1997"]
    end

    test "a row with fewer values than there are columns leaves the cell blank", %{
      conn: conn,
      swiss: swiss
    } do
      short =
        update_in(swiss, ["standings", "rows", Access.at(0), "tiebreaks"], &Enum.take(&1, 2))

      publish(short)

      document = conn |> get(~p"/t/#{short["tournament"]["slug"]}") |> doc()

      # Rank 1 is player 9 now that standings stop after round 2 - no
      # title, so the name renders alone.
      assert cell_values(document, "table.standings > tbody > tr:first-child > td") ==
               ["1", "De Smet, Jean-Baptiste", "1742", "B", "2", "1", "1.5", "", ""]
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
               ["1", "Ó Braonáin, Cillian", "1690", "12", "8", "1"]
    end

    test "a player with no rating, title or club renders cleanly", %{conn: conn, slug: slug} do
      # Player 10 has none of the three. Club play is mostly missing fields.
      document = conn |> get(~p"/t/#{slug}") |> doc()

      # This file is written by OpenPairings' own `snapshot_test.exs`, so
      # this repo tests against real builder output rather than a value
      # typed in by hand. Standings now stop after round 2, not round 3, so
      # player 10's Buchholz Cut-1 and Buchholz each carry one round less
      # than they used to. Nothing here changed - the numbers it is given
      # did.
      assert cell_values(document, "table.standings > tbody > tr:last-child > td") ==
               ["10", "Nguyễn, Thị Hà", "-", "B", "0", "1", "1", "0", "0"]
    end

    test "a tournament with nothing published at all still says so plainly", %{conn: conn} do
      # Genuinely nothing - no players either - is the one case the starting
      # rank cannot stand in for, and it keeps the original message.
      payload =
        SnapshotPayloads.swiss()
        |> Map.delete("standings")
        |> Map.put("players", [])
        |> put_in(["tournament", "slug"], "empty-open")

      publish(payload)

      html = conn |> get(~p"/t/empty-open") |> html_response(200)

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

  describe "GET /t/:slug - the starting rank fallback, before round one" do
    test "shows the starting rank instead of an empty standings table", %{
      conn: conn,
      swiss: swiss
    } do
      publish(no_rounds(swiss))
      document = conn |> get(~p"/t/#{swiss["tournament"]["slug"]}") |> doc()

      assert texts(document, "h2") == ["Standings before round 1"]
      refute texts(document, "p.empty") |> Enum.any?(&(&1 =~ "No standings"))
    end

    test ~s(never says "after round 0"), %{conn: conn, swiss: swiss} do
      publish(no_rounds(swiss))
      html = conn |> get(~p"/t/#{swiss["tournament"]["slug"]}") |> html_response(200)

      refute html =~ "after round 0"
      refute html =~ "after round"
    end

    test "players are listed in starting-number order, not the payload's own order", %{
      conn: conn,
      swiss: swiss
    } do
      shuffled = update_in(swiss["players"], &Enum.shuffle/1)
      publish(no_rounds(shuffled))

      document = conn |> get(~p"/t/#{swiss["tournament"]["slug"]}") |> doc()

      assert texts(document, "table.starting-rank tbody tr td:first-child") ==
               ~w(1 2 3 4 5 6 7 8 9 10)
    end

    test "every name still links to its player card", %{conn: conn, swiss: swiss} do
      publish(no_rounds(swiss))
      document = conn |> get(~p"/t/#{swiss["tournament"]["slug"]}") |> doc()

      assert "Müller, Jörg" in texts(document, "table.starting-rank a.player .name")

      assert LazyHTML.query(
               document,
               ~s(table.starting-rank a[href="/t/#{swiss["tournament"]["slug"]}/player/1"])
             )
             |> Enum.any?()
    end

    test "a keizer tournament gets the fallback too", %{conn: conn, keizer: keizer} do
      publish(no_rounds(keizer))
      html = conn |> get(~p"/t/#{keizer["tournament"]["slug"]}") |> html_response(200)

      assert html =~ "before round 1"
      assert html =~ "Peeters, Wouter"
    end

    test "the standings page's own description says so too, before round 1", %{
      conn: conn,
      swiss: swiss
    } do
      publish(no_rounds(swiss))
      html = conn |> get(~p"/t/#{swiss["tournament"]["slug"]}") |> html_response(200)

      assert html =~ "Standings of Gent Spring Open 2026, before round 1."
    end

    test "a tournament with a real standings table is unaffected", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert texts(document, "h2") == ["Standings after round 2"]
      assert texts(document, "table.starting-rank") == []
    end
  end

  describe "GET /t/:slug/round/:n - pairings" do
    test "renders board, ratings, running scores, white, result and black", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert texts(document, "h2") == ["Round 1 2026-03-01"]

      # Elo, and the points each player carried INTO the round - which is what
      # a pairing list means by score, and what explains why these two are on
      # board 1. The points they end the round with are on the standings.
      assert texts(document, "table.pairings tbody tr:first-child td") ==
               ["1", "2601", "0", "GM Müller, Jörg", "1-0", "WIM Ștefănescu, Ioana", "0", "2033"]
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
               "Łukasiewicz, Paweł 2208 pairing-allocated bye 1",
               "Nguyễn, Thị Hà - absent 0"
             ]
    end

    test "a vacated seat is named as one, with the result that explains it", %{
      conn: conn,
      swiss: swiss
    } do
      # The row OpenPairings started sending once it stopped calling every
      # one-seated board a pairing-allocated bye. It is not a bye: the
      # arbiter emptied the opposite seat and recorded a forfeit, so the
      # points are the forfeit's and the label has to say so.
      vacated =
        update_in(swiss, ["rounds", Access.at(1), "byes"], fn byes ->
          [
            %{
              "player" => 3,
              "kind" => "vacated-seat",
              "result" => "0-1FF",
              "points" => 0.0
            }
            | byes
          ]
        end)

      publish(vacated)

      document = conn |> get(~p"/t/#{vacated["tournament"]["slug"]}/round/2") |> doc()

      assert "FM Ó Súilleabháin, Séamus 2312 seat vacated ( 0-1 forfeit ) 0" in texts(
               document,
               "table.byes tbody tr"
             )
    end

    test "a kind this server has never heard of is still shown", %{conn: conn, swiss: swiss} do
      # The rule the whole contract leans on, restated for byes: a newer
      # OpenPairings inventing a sixth kind must produce a page an arbiter
      # can read, not a blank cell. This is also what makes the row above
      # safe to send to a server deployed before it existed.
      future =
        update_in(swiss, ["rounds", Access.at(1), "byes"], fn byes ->
          [%{"player" => 3, "kind" => "invented-in-2027", "points" => 0.25} | byes]
        end)

      publish(future)

      document = conn |> get(~p"/t/#{future["tournament"]["slug"]}/round/2") |> doc()

      assert "FM Ó Súilleabháin, Séamus 2312 invented-in-2027 0.25" in texts(
               document,
               "table.byes tbody tr"
             )
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

      assert texts(document, "nav.rounds a.chip") ==
               ["Standings", "Cross-table", "1", "2", "3", "5"]

      assert texts(document, "nav.rounds span.chip.withheld") == ["4, not published"]
    end
  end

  describe "GET /t/:slug/round/:n?display=1 - the projector view" do
    test "renders the boards, projected", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/1?display=1") |> doc()

      assert texts(document, "[data-projector] .projector-round") == ["Round 1 2026-03-01"]

      assert texts(document, "table.projector-pairings tbody tr:first-child td") ==
               ["1", "GM Müller, Jörg", "1-0", "WIM Ștefănescu, Ioana"]
    end

    test "the ordinary URL is unchanged", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert texts(document, "[data-projector]") == []
      assert texts(document, "table.pairings.projector-pairings") == []

      assert texts(document, "table.pairings tbody tr:first-child td") ==
               ["1", "2601", "0", "GM Müller, Jörg", "1-0", "WIM Ștefănescu, Ioana", "0", "2033"]
    end

    test "a name is plain text, not a link - a tap here pauses the cycle", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/round/1?display=1") |> doc()

      assert texts(document, "table.projector-pairings a.player") == []
      assert texts(document, "table.projector-pairings span.player .name") != []
    end

    test "the page counter and bar are in the markup but hidden, for the script to reveal", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/round/1?display=1") |> doc()

      foot = LazyHTML.query(document, "#projector-foot")
      assert LazyHTML.attribute(foot, "hidden") == [""]
    end

    test "byes still appear, statically, underneath the boards", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/2?display=1") |> doc()

      assert texts(document, ".projector-byes table.byes tbody tr") == [
               "Łukasiewicz, Paweł 2208 pairing-allocated bye 1",
               "Nguyễn, Thị Hà - absent 0"
             ]
    end

    test "a round the arbiter withheld is still a 404", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/round/4?display=1") |> html_response(404)

      assert html =~ "Round 4 of Gent Spring Open 2026 has not been published"
    end

    test "an unrecognised display value is the ordinary page, not the projector", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/round/1?display=0") |> doc()

      assert texts(document, "[data-projector]") == []
    end
  end

  describe "GET /t/:slug/player/:no - the card" do
    setup %{swiss: swiss} do
      # The fixture's own `after_round` is 2, with rounds 1, 2, 3 and 5
      # already published - the standings gate is a describe block of its
      # own, below. Every test in THIS block is about the card's own
      # per-round logic (colour, opponent, the running score, a bye's own
      # row...), not about the gate, so `after_round` is pushed up to the
      # last published round here and these assertions read exactly as they
      # did before the gate existed.
      swiss |> put_in(["standings", "after_round"], 5) |> publish()
      :ok
    end

    test "one row per round, with colour, opponent, result and running score", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      # The opponent's number, federation, title, rating and own total - the
      # same detail the arbiter's own Players Card carries, and the reason 4/5
      # against the top boards reads differently from 4/5 against the bottom.
      assert texts(document, "table.card tbody tr") == [
               "1 White 6 ROU WIM Ștefănescu, Ioana 2033 0 1-0 1",
               "2 Black 2 SRB IM Đurić, Nikola 2455 1.5 1/2-1/2 1.5",
               "3 White 3 IRL FM Ó Súilleabháin, Séamus 2312 1.5 1-0 2.5",
               "4 not published",
               "5 Black 2 SRB IM Đurić, Nikola 2455 1.5 0-1"
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

    # The text was always right; the PLACE was not. The label used to span
    # from "No" onwards, so it started two or three columns to the left of
    # every opponent's name above and below it and read as if it had landed
    # in the wrong column. It sits under "Opponent" now, like a name.
    test "a bye's label lines up under the opponent column", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/player/4") |> doc()

      headers = texts(document, "table.card thead th")
      opponent_at = Enum.find_index(headers, &(&1 == "Opponent"))
      # Opponent, Elo and Pts: what a game row fills with the opponent's detail.
      span_wanted = Enum.find_index(headers, &(&1 == "Result")) - opponent_at

      {label_at, label_span} =
        document
        |> LazyHTML.query("table.card tbody tr:nth-child(2) td")
        |> Enum.reduce_while(0, fn cell, column ->
          span = cell |> LazyHTML.attribute("colspan") |> List.first("1") |> String.to_integer()

          if LazyHTML.text(cell) =~ "bye",
            do: {:halt, {column, span}},
            else: {:cont, column + span}
        end)

      assert label_at == opponent_at
      assert label_span == span_wanted
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

  describe "GET /t/:slug/player/:no - the standings gate" do
    test "only rounds the standings already cover show, even though later rounds are live", %{
      conn: conn,
      slug: slug
    } do
      # The fixture's own shape, untouched: standings stop after round 2
      # while rounds 1, 2, 3 and 5 are already published and full of
      # results. Rounds 3 and 5 are exactly as published as 1 and 2 are;
      # they are simply not folded into the standings this card must agree
      # with yet - contrast with "GET /t/:slug/player/:no - the card" above,
      # which bumps `after_round` past them precisely so it can test
      # everything else about the card without this gate in the way.
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert texts(document, "table.card tbody tr") == [
               "1 White 6 ROU WIM Ștefănescu, Ioana 2033 0 1-0 1",
               "2 Black 2 SRB IM Đurić, Nikola 2455 1.5 1/2-1/2 1.5"
             ]
    end

    test "a round's own page is unaffected and still shows it live", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}/round/3") |> html_response(200) =~ "1/2-0"
      assert conn |> get(~p"/t/#{slug}/round/5") |> html_response(200) =~ "Round 5"
    end

    test "the placing above the card never counts a later round's result", %{
      conn: conn,
      slug: slug
    } do
      # Player 9 sits on 2.0 points after round 2 - the fixture's own
      # standings - and round 5, already live, gives them a further win
      # (board: white 10, black 9, "0-1"). The summary above the card reads
      # `standings.rows` directly and must still say 2, not 3: the gate
      # exists so nothing else can sneak a later round's result in by
      # another route.
      document = conn |> get(~p"/t/#{slug}/player/9") |> doc()

      assert texts(document, ".placing") == ["1 of 10, on 2"]
    end

    test "the empty state before any standings are published, even with rounds live", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      # Rounds 1, 2, 3 and 5 stay exactly as published - only the standings
      # change, to the state OpenPairings writes before it has closed round
      # one: `after_round: 0` and no rows. See `Tournament.after_round/1`'s
      # own doc for why 0 has to read the same way absence does.
      before_round_one =
        swiss
        |> put_in(["standings", "after_round"], 0)
        |> put_in(["standings", "rows"], [])

      publish(before_round_one)
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert texts(document, "p.empty") == [
               "Results appear here once the standings after round 1 are published."
             ]

      assert texts(document, "table.card") == []
      assert texts(document, ".chart") == []

      # And the round page beside it could not care less.
      assert conn |> get(~p"/t/#{slug}/round/1") |> html_response(200) =~ "1-0"
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

      # This used to refuse any <script> at all. Two inline ones arrived on
      # 2026-08-29 - a theme preference reader and a right-click handler -
      # and the promise they had to keep is the one below, not the absence of
      # the tag: the result is in the HTML that lands, and everything else is
      # decoration that can fail without taking the page with it.
      assert html =~ "1-0"
      assert html =~ "Müller, Jörg"

      # No bundle, and nothing to fetch before the page means something. An
      # external script is a second request on a playing hall's wifi and a
      # blank table until it answers.
      refute html =~ ~s|<script src|
      refute html =~ ~s|<script defer|
      refute html =~ "phx-track-static"

      # Still no session anywhere near this site.
      refute html =~ "csrf-token"
    end

    test "the refresher targets a region, not the page", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)

      # The contract between the server-rendered page and the refresher: it
      # replaces this region and nothing else, so the theme, the scroll
      # position and an open card all survive an update.
      #
      # (There is no `refute html =~ "location.reload"` here, tempting as it
      # was - the script's own comment explains why it does not reload, so
      # that assertion tested the prose rather than the behaviour.)
      assert html =~ ~s|id="live-region"|

      # And it must leave the entry form alone: replacing the DOM under
      # somebody mid-sentence would clear what they had typed.
      form = conn |> get(~p"/t/#{slug}/register") |> html_response(200)
      assert form =~ "registration-form"
      assert form =~ "isForm"
    end

    test "the scripts that are here are inert if they never run", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/round/1") |> html_response(200)

      # A player's name is a real link to a real page. The right-click card
      # replaces that navigation; it does not create it, so a browser with
      # JavaScript off loses a convenience rather than a feature.
      assert html =~ ~s|href="/t/#{slug}/player/1"|

      # The theme picker is hidden until the script marks the document, so a
      # control that cannot work is never offered. `has-js` is added by the
      # inline reader in <head>.
      assert html =~ "theme-picker"
      assert html =~ "has-js"
    end

    test "an untouched visitor gets the light theme, not the device's", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)

      # Following the device is the better default for an app somebody lives
      # in. This is a page opened once, often inside a club's own site - and
      # club sites are overwhelmingly light, so a dark slab dropped into the
      # middle of one reads as broken rather than as a theme.
      assert html =~ ~s|root.setAttribute("data-theme", "paper")|

      # "Match device" is still one click away, and still wins once chosen.
      assert html =~ ~s|data-theme-opt="system"|
    end
  end
end
