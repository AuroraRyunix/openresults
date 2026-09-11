defmodule OpenResultsWeb.CrosstableTest do
  @moduledoc """
  The grid: who played whom, and what happened.

  Half of this file is about one mistake. A board carries `1-0`, which is a
  win for the seat on the left of the token and a loss for the seat on the
  right, so a cross-table that prints the board's own result in both players'
  rows tells the loser they won. It reads perfectly from either half on its
  own, which is why it survives review - so every assertion here that could
  check one side checks both sides of the same board.

  The rest is about the things that are not results: a bye, a forfeit, a game
  still being played, and a round somebody is simply not in. A cross-table
  that renders those as scores is worse than no cross-table, because it is
  wrong in a way that looks right.
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
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

  defp publish(payload), do: {:ok, _snapshot} = Snapshots.ingest(payload)

  # Replaces the display map wholesale, so every key not named here is absent
  # - which means shown, the rule the whole contract leans on.
  defp hiding(payload, keys) do
    put_in(payload, ["tournament", "display"], Map.new(keys, &{&1, false}))
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  defp attributes(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp grid(conn, slug), do: conn |> get(~p"/t/#{slug}/crosstable") |> doc()

  # No, Player and Elo, so the first round sits in the fourth column.
  @first_round 4

  # The cell in player `no`'s row for the `index`-th PUBLISHED round - index
  # 3 is round 3 and index 4 is round 5, because round 4 was never published.
  #
  # Rows are in starting-number order, so player `no` is row `no` in this
  # fixture. That is asserted outright below rather than assumed here.
  defp cell(document, no, index) do
    document
    |> texts(
      "table.crosstable tbody tr:nth-child(#{no}) td:nth-child(#{@first_round + index - 1})"
    )
    |> List.first()
  end

  describe "the shape of the grid" do
    test "one row per player, in starting-number order", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      # Not the standings' order, which is the arbiter's answer and is right
      # there. Every cell names its opponent by number and nothing else, so a
      # reader who has just read "6w1" wants to find row 6 by counting.
      assert texts(document, "table.crosstable tbody td.xt-no") == ~w(1 2 3 4 5 6 7 8 9 10)

      assert texts(document, "table.crosstable tbody tr:first-child td.xt-name") ==
               ["GM Müller, Jörg"]
    end

    test "one column per published round, and none for the round nobody published", %{
      conn: conn,
      slug: slug
    } do
      document = grid(conn, slug)

      # Round 4 is absent from the payload. The masthead's round strip shows
      # it as a gap on purpose - a strip is a list of what exists - but an
      # empty column in a table of results reads as a round nobody turned up
      # to, which is a different and untrue claim.
      assert texts(document, "table.crosstable thead th") ==
               ["No", "Player", "Elo", "1", "2", "3", "5", "Points", "Rank"]
    end

    test "each round heading is a link to that round's own page", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      assert attributes(document, "table.crosstable thead .xt-round a", "href") == [
               "/t/#{slug}/round/1",
               "/t/#{slug}/round/2",
               "/t/#{slug}/round/3",
               "/t/#{slug}/round/5"
             ]
    end

    test "it scrolls inside its own box, with the two key columns marked to stay put", %{
      conn: conn,
      slug: slug
    } do
      document = grid(conn, slug)

      # A 450-player grid is wider than any screen. `.scroller` is what keeps
      # that sideways scrolling inside the table instead of moving the page
      # body, and the two pinned columns are what stop a reader who has
      # scrolled to round 9 from looking at numbers belonging to nobody.
      assert texts(document, "div.scroller table.crosstable thead th") != []
      assert length(texts(document, "table.crosstable tbody td.xt-no")) == 10
      assert length(texts(document, "table.crosstable tbody td.xt-name")) == 10
    end

    test "an opponent's number is a link to their card", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      assert attributes(
               document,
               "table.crosstable tbody tr:first-child .xt-cell a.player",
               "href"
             ) ==
               [
                 "/t/#{slug}/player/6",
                 "/t/#{slug}/player/2",
                 "/t/#{slug}/player/3",
                 "/t/#{slug}/player/2"
               ]
    end
  end

  describe "the result is read from the row player's own side" do
    test "both halves of a decided game", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      # Round 1, board 1: player 1 had White and beat player 6. Printing the
      # board's own "1-0" in both rows is the classic bug, and it is only
      # visible from the losing side.
      assert cell(document, 1, 1) == "6 w 1"
      assert cell(document, 6, 1) == "1 b 0"
    end

    test "both halves of a game the row player lost with White", %{conn: conn, slug: slug} do
      # Round 1, board 2: player 7 had White and lost. The colour and the
      # score are independent, and a cell that derived one from the other
      # would still pass the test above.
      document = grid(conn, slug)

      assert cell(document, 7, 1) == "2 w 0"
      assert cell(document, 2, 1) == "7 b 1"
    end

    test "both halves of a draw", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      assert cell(document, 3, 1) == "8 w 0.5"
      assert cell(document, 8, 1) == "3 b 0.5"
    end

    test "both halves of an asymmetric result, where the two do not add up to one", %{
      conn: conn,
      slug: slug
    } do
      # Round 3, board 2: "1/2-0", the VCL.13 result. White keeps half a
      # point and Black gets nothing, so a cell that read "the other side got
      # whatever I did not" would print 0.5 for Black.
      document = grid(conn, slug)

      assert cell(document, 4, 3) == "2 w 0.5"
      assert cell(document, 2, 3) == "4 b 0"
    end

    test "both halves of a forfeit, which is worth its point and was never played", %{
      conn: conn,
      slug: slug
    } do
      # Round 1, board 4: "1-0FF". The point counts; the game did not happen.
      # Both facts have to survive being one character wide.
      document = grid(conn, slug)

      assert cell(document, 9, 1) == "4 w 1 forfeit"
      assert cell(document, 4, 1) == "9 b 0 forfeit"
    end

    test "both halves of a game that will not move a rating", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      assert cell(document, 5, 1) == "10 w 1 unrated"
      assert cell(document, 10, 1) == "5 b 0 unrated"
    end

    test "and the colours agree with the round page they came from", %{conn: conn, slug: slug} do
      # The same board, read off both pages. A cross-table that swapped the
      # colours would be self-consistent and disagree with the pairing list
      # printed in the hall.
      round = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert texts(round, "table.pairings tbody tr:first-child td") ==
               ["1", "2601", "0", "GM Müller, Jörg", "1-0", "WIM Ștefănescu, Ioana", "0", "2033"]

      document = grid(conn, slug)

      assert cell(document, 1, 1) == "6 w 1"
    end
  end

  describe "what is not a result" do
    test "a game with no result yet is a marker in both rows, not a zero", %{
      conn: conn,
      slug: slug
    } do
      # Round 3, board 3: still being played. A blank would read as a board
      # nobody has typed in and a zero would be a game somebody lost.
      document = grid(conn, slug)

      assert cell(document, 8, 3) == "5 w -"
      assert cell(document, 5, 3) == "8 b -"
    end

    test "a bye carries the arbiter's own word for it and the arbiter's own value", %{
      conn: conn,
      slug: slug
    } do
      document = grid(conn, slug)

      # The value is configurable, so a half-point bye worth something else
      # is the arbiter's decision to state and not this page's to assume.
      assert cell(document, 4, 2) == "1 pairing-allocated bye"
      assert cell(document, 10, 2) == "0 absent"
      assert cell(document, 6, 3) == "0.5 half-point bye"
      assert cell(document, 9, 3) == "0 zero-point bye"
    end

    test "a bye kind this server has never heard of is still shown", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      # The rule the whole contract leans on: a newer OpenPairings inventing
      # a seventh kind must produce a cell an arbiter can read, not a blank.
      # Player 7 is in no board of round 3, which is where this one goes.
      future =
        update_in(swiss, ["rounds", Access.at(2), "byes"], fn byes ->
          [%{"player" => 7, "kind" => "invented-in-2027", "points" => 0.25} | byes]
        end)

      publish(future)

      assert cell(grid(conn, slug), 7, 3) == "0.25 invented-in-2027"
    end

    test "a player somehow given both a board and a bye is shown the game", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      # Not a payload anything sane produces, but the two pages must not
      # disagree about the same round if it ever arrives. The player card
      # takes the board; so does this.
      both =
        update_in(swiss, ["rounds", Access.at(1), "byes"], fn byes ->
          [%{"player" => 3, "kind" => "half-point", "points" => 0.5} | byes]
        end)

      publish(both)

      assert cell(grid(conn, slug), 3, 2) == "6 b 1"

      assert conn
             |> get(~p"/t/#{slug}/player/3")
             |> doc()
             |> texts("table.card tbody tr:nth-child(2)") ==
               ["2 Black 6 ROU WIM Ștefănescu, Ioana 2033 0.5 0-1 1.5"]
    end

    test "a round a player is not listed in is empty, which is not the same as a zero", %{
      conn: conn,
      slug: slug
    } do
      # Players 7 and 10 are in no board and no bye of round 3. Unpaired, or
      # a board the arbiter hid - the payload cannot tell the two apart, so
      # the cell says nothing rather than choosing.
      document = grid(conn, slug)

      assert cell(document, 7, 3) == ""
      assert cell(document, 10, 3) == ""

      # And it says so to anyone who asks, in the words the player card uses.
      assert attributes(document, "table.crosstable tbody tr:nth-child(7) td.xt-empty", "title") ==
               ["no game published for this round"]
    end

    test "a result token this server cannot read is shown as it arrived, and scores nobody", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      # Neither half of "1-0ADJ" can be handed to a seat without inventing a
      # meaning, and printing the whole token in both rows would tell the
      # loser they won. So both rows show the board's token and no score.
      invented =
        put_in(swiss, ["rounds", Access.at(0), "boards", Access.at(0), "result"], "1-0ADJ")

      publish(invented)
      document = grid(conn, slug)

      assert cell(document, 1, 1) == "6 w 1-0ADJ"
      assert cell(document, 6, 1) == "1 b 1-0ADJ"
    end
  end

  describe "the placings beside the grid" do
    test "are the arbiter's own, not this page's arithmetic", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      assert texts(document, "table.crosstable tbody tr:first-child td") ==
               ["1", "GM Müller, Jörg", "2601", "6 w 1", "2 b 0.5", "3 w 1", "2 b 1", "2.5", "1"]

      # Player 9 is second on 2 points, above three players on 1.5 - which is
      # a tiebreak's answer and not something this page could work out.
      assert texts(document, "table.crosstable tbody tr:nth-child(9) td:last-child") == ["2"]
    end

    test "and go entirely when the arbiter does not publish standings", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      publish(hiding(swiss, ["standings"]))
      document = grid(conn, slug)

      assert texts(document, "table.crosstable thead th") ==
               ["No", "Player", "Elo", "1", "2", "3", "5"]

      # The grid itself is untouched. Hiding the league table is not hiding
      # the results, and this page is readable without either column.
      assert cell(document, 1, 1) == "6 w 1"
    end

    test "a Keizer ladder shows the game score rather than its own currency", %{conn: conn} do
      # The one system where "points" beside a row of results would be a
      # contradiction rather than a total: player 1 won both games and has 17
      # Keizer points, which are a function of who they beat and not of how
      # many. The ladder's own number stays on the standings, under the
      # column that says what it is.
      keizer = SnapshotPayloads.keizer()
      publish(keizer)
      document = grid(conn, keizer["tournament"]["slug"])

      assert texts(document, "table.crosstable thead th") ==
               ["No", "Player", "Elo", "1", "2", "Score", "Rank"]

      assert texts(document, "table.crosstable tbody tr:first-child td") ==
               ["1", "Peeters, Wouter", "2088", "4 w 1", "6 b 1", "2", "1"]
    end

    test "a tournament that has not ranked anybody yet gets no empty columns", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      publish(Map.delete(swiss, "standings"))
      document = grid(conn, slug)

      assert texts(document, "table.crosstable thead th") ==
               ["No", "Player", "Elo", "1", "2", "3", "5"]
    end
  end

  describe "what the arbiter withholds" do
    test "the pairings tick takes the grid with it", %{conn: conn, slug: slug, swiss: swiss} do
      # The cross-table IS the pairings, transposed. An arbiter who withheld
      # the round pages and then found every board on a grid one click away
      # would have been handed a page that undoes their own setting.
      publish(hiding(swiss, ["pairings"]))

      assert conn |> get(~p"/t/#{slug}/crosstable") |> html_response(404) =~
               "does not publish round pairings"
    end

    test "and so does the grid's own tick", %{conn: conn, slug: slug, swiss: swiss} do
      publish(hiding(swiss, ["crosstable"]))

      assert conn |> get(~p"/t/#{slug}/crosstable") |> html_response(404) =~
               "does not publish round pairings"

      # Only the grid. The round pages it is made of are untouched.
      assert conn |> get(~p"/t/#{slug}/round/1") |> html_response(200) =~ "Round 1"
    end

    test "a tick this server has never heard of leaves the page alone", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      publish(hiding(swiss, ["invented_in_2027"]))

      assert conn |> get(~p"/t/#{slug}/crosstable") |> html_response(200) =~ "Cross-table"
    end

    test "ratings go from this table like every other", %{conn: conn, slug: slug, swiss: swiss} do
      publish(hiding(swiss, ["rating"]))
      document = grid(conn, slug)

      assert texts(document, "table.crosstable thead th") ==
               ["No", "Player", "1", "2", "3", "5", "Points", "Rank"]
    end

    test "with cards off the numbers stay and the links go", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      publish(hiding(swiss, ["player_cards"]))
      document = grid(conn, slug)

      assert attributes(document, "table.crosstable a.player", "href") == []

      # Turning cards off must not turn the grid into blanks: the whole page
      # is opponents named by number.
      assert texts(document, "table.crosstable tbody tr:first-child td:nth-child(4)") == ["6 w 1"]
    end

    test "the byes tick does not blank a bye out of the grid", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      # A decision worth writing down rather than a gap. That tick governs
      # the byes TABLE under a round's boards; the player card has always
      # shown a player's own byes regardless of it, and this page is the
      # card's shape rather than the round's.
      #
      # Blanking the cell would also be a lie of a kind this site does not
      # tell: an empty cell here means "not listed in this round", and a
      # player who took a bye was listed.
      publish(hiding(swiss, ["byes"]))
      document = grid(conn, slug)

      assert cell(document, 4, 2) == "1 pairing-allocated bye"

      # The round page still honours it, which is what the tick is about.
      refute conn |> get(~p"/t/#{slug}/round/2") |> html_response(200) =~ "pairing-allocated bye"
    end

    test "a tournament with no published round says so instead of showing an empty grid", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      publish(Map.put(swiss, "rounds", []))

      assert conn |> get(~p"/t/#{slug}/crosstable") |> html_response(200) =~
               "No rounds have been published"
    end
  end

  describe "finding it" do
    test "every page of the tournament links to it", %{conn: conn, slug: slug} do
      # A page nothing navigates to does not exist.
      for path <- [~p"/t/#{slug}", ~p"/t/#{slug}/round/1", ~p"/t/#{slug}/player/1"] do
        assert conn |> get(path) |> html_response(200) =~ ~s|href="/t/#{slug}/crosstable"|,
               "#{path} does not link to the cross-table"
      end
    end

    test "and the chip is marked while you are on it", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      assert texts(document, "nav.rounds a.chip.current") == ["Cross-table"]

      assert texts(document, "nav.rounds a.chip") == [
               "Standings",
               "Starting rank",
               "Cross-table",
               "1",
               "2",
               "3",
               "5"
             ]
    end

    test "the link is not offered when the page is not there", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      publish(hiding(swiss, ["crosstable"]))

      refute conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "/crosstable"
    end
  end

  describe "the page itself" do
    test "says what it is when the link is pasted somewhere else", %{conn: conn, slug: slug} do
      document = grid(conn, slug)

      assert texts(document, "title") == ["Gent Spring Open 2026 - Cross-table - OpenResults"]

      assert attributes(document, ~s|meta[name="description"]|, "content") == [
               "Every published result of Gent Spring Open 2026, round by round, as one cross-table. Ghent, 2026-03-01 to 2026-03-05."
             ]
    end

    test "and never leaks a city or dates the arbiter turned off", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      # A meta description travels off the site entirely, into a chat app,
      # where nobody who could notice will ever see it.
      publish(hiding(swiss, ["city", "dates"]))

      [description] = attributes(grid(conn, slug), ~s|meta[name="description"]|, "content")

      refute description =~ "Ghent"
      refute description =~ "2026-03-01"
      assert description =~ "Gent Spring Open 2026"
    end

    test "revalidates and is stored like every other read page", %{conn: conn, slug: slug} do
      answer = get(conn, ~p"/t/#{slug}/crosstable")
      tag = answer |> get_resp_header("etag") |> List.first()

      assert answer.status == 200
      assert tag
      assert get_resp_header(answer, "cache-control") == ["private, no-cache"]

      # A read route that misses the plug is simply never cached, and nothing
      # anywhere says so. This is the proof that it did not: the rendered
      # body is in the store, under this tournament's current version.
      assert Page.get(slug, Snapshots.latest_id(slug), "en", tag) == answer.resp_body

      unchanged =
        build_conn() |> put_req_header("if-none-match", tag) |> get(~p"/t/#{slug}/crosstable")

      assert unchanged.status == 304

      # And it is a page in its own right: a reader arriving from the
      # standings must not be told the page they have not seen is unchanged.
      standings = build_conn() |> get(~p"/t/#{slug}") |> get_resp_header("etag") |> List.first()
      refute standings == tag
    end

    test "renders in Dutch and in French", %{slug: slug} do
      dutch =
        build_conn()
        |> put_req_header("accept-language", "nl")
        |> get(~p"/t/#{slug}/crosstable")
        |> html_response(200)

      assert dutch =~ "Kruistabel"
      assert dutch =~ "tegenstander"

      french =
        build_conn()
        |> put_req_header("accept-language", "fr")
        |> get(~p"/t/#{slug}/crosstable")
        |> html_response(200)

      assert french =~ "Grille américaine"
      assert french =~ "adversaire"
    end

    test "spells the notation out, because a cross-table is notation first", %{
      conn: conn,
      slug: slug
    } do
      document = grid(conn, slug)

      # The two letters are not translated - they are what a TRF file and a
      # printed pairing sheet say in every language - so the sentence under
      # the table has to carry their meaning in the reader's own.
      footnote = document |> texts("p.footnote") |> Enum.join(" ")

      assert footnote =~ "w for White"
      assert footnote =~ "b for Black"

      assert attributes(document, "table.crosstable tbody .xt-colour", "title")
             |> Enum.uniq()
             |> Enum.sort() == ["Black", "White"]
    end
  end
end
