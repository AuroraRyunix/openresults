defmodule OpenResultsWeb.TeamPagesTest do
  @moduledoc """
  Team standings, matches on round pages, team pages and board prizes - the
  additive team fields from `docs/snapshot-schema.md`, and the fallback for a
  payload (an individual tournament, or a team Swiss that has not scheduled a
  single match yet) that does not carry them.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.Snapshots
  alias OpenResults.SnapshotPayloads

  setup do
    team_rr = SnapshotPayloads.team_round_robin()
    team_swiss = SnapshotPayloads.team_swiss()
    swiss = SnapshotPayloads.swiss()

    {:ok, _} = Snapshots.ingest(team_rr)

    {:ok, _} =
      Snapshots.ingest(
        team_swiss
        |> Map.put("tournament", Map.put(team_swiss["tournament"], "slug", "team-swiss-fixture"))
      )

    {:ok, _} = Snapshots.ingest(swiss)

    {:ok,
     team_rr: team_rr,
     rr_slug: team_rr["tournament"]["slug"],
     swiss_slug: swiss["tournament"]["slug"],
     team_swiss_slug: "team-swiss-fixture"}
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  describe "the tournament page, team round robin" do
    test "shows the team standings table, not the individual one", %{conn: conn, rr_slug: slug} do
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert texts(document, "table.standings caption") != []
      assert texts(document, "th.row-head a") |> Enum.any?(&(&1 =~ "Antwerp Knights"))
      # No individual standings table alongside it.
      refute texts(document, "th.row-head") |> Enum.any?(&(&1 =~ "Antwerp Knights 1"))
    end

    test "each team name links to its own page", %{conn: conn, rr_slug: slug} do
      document = conn |> get(~p"/t/#{slug}") |> doc()

      hrefs =
        document
        |> LazyHTML.query("table.standings a")
        |> Enum.map(&LazyHTML.attribute(&1, "href"))

      assert Enum.any?(List.flatten(hrefs), &String.contains?(&1, "/team/"))
    end

    test "offers the team cross-table for a round robin", %{conn: conn, rr_slug: slug} do
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)
      assert html =~ "Team cross-table"
    end
  end

  describe "a round page, team round robin" do
    test "lists the round's matches, expandable to their boards", %{conn: conn, rr_slug: slug} do
      html = conn |> get(~p"/t/#{slug}/round/1") |> html_response(200)

      assert html =~ "table class=\"matches\""
      assert html =~ "<details>"
      assert html =~ "Boards"
    end

    test "the team filter narrows the board lines", %{conn: conn, rr_slug: slug, team_rr: payload} do
      team_no = payload["teams"] |> hd() |> Map.get("no")

      document = conn |> get(~p"/t/#{slug}/round/1?team=#{team_no}") |> doc()
      assert texts(document, ".filter-pill") |> Enum.any?(&(&1 =~ "Team"))
    end
  end

  describe "GET /t/:slug/team/:no" do
    test "renders the roster in board order and the match history", %{
      conn: conn,
      rr_slug: slug,
      team_rr: payload
    } do
      team = hd(payload["teams"])

      document = conn |> get(~p"/t/#{slug}/team/#{team["no"]}") |> doc()

      assert texts(document, "h2") |> Enum.any?(&String.contains?(&1, team["name"]))
      assert texts(document, "h3") == ["Roster", "Matches"]
    end

    test "404s for a team that does not exist", %{conn: conn, rr_slug: slug} do
      conn |> get(~p"/t/#{slug}/team/999") |> html_response(404)
    end
  end

  describe "a match forfeited by decision (matches[].forfeit_decision)" do
    # The fixture's round 1 with its second match - Brugse SK against
    # Charleroi - carrying `forfeit` as that match's `forfeit_decision`, the
    # first match `null`, under its own slug. `forfeit: :absent` deletes the
    # key from every match, as a publisher older than the field sends it.
    defp forfeit_payload(payload, slug, forfeit, round_fun \\ & &1) do
      rounds =
        Enum.map(payload["rounds"], fn round ->
          matches =
            round
            |> Map.get("matches", [])
            |> Enum.map(fn match ->
              cond do
                forfeit == :absent -> Map.delete(match, "forfeit_decision")
                match["number"] == 2 -> Map.put(match, "forfeit_decision", forfeit)
                true -> Map.put(match, "forfeit_decision", nil)
              end
            end)

          round_fun.(Map.put(round, "matches", matches))
        end)

      payload
      |> Map.put("rounds", rounds)
      |> put_in(["tournament", "slug"], slug)
    end

    defp ingest!(payload), do: {:ok, _} = Snapshots.ingest(payload)

    defp charleroi(payload), do: Enum.find(payload["teams"], &(&1["name"] == "Charleroi"))

    test "present: the round page's match line and both teams' histories say so, boards still listed",
         %{conn: conn, team_rr: payload} do
      to = charleroi(payload)["no"]
      ingest!(forfeit_payload(payload, "forfeit-present", %{"to" => to}))

      document = conn |> get(~p"/t/forfeit-present/round/1") |> doc()
      assert texts(document, ".match-forfeit") == ["Awarded to Charleroi by the arbiter"]
      # The match's boards are still there to expand.
      assert Enum.count(LazyHTML.query(document, "table.matches details")) == 2

      for team_no <- [to, Enum.find(payload["teams"], &(&1["name"] == "Brugse SK"))["no"]] do
        document = conn |> get(~p"/t/forfeit-present/team/#{team_no}") |> doc()
        assert texts(document, ".match-forfeit") == ["Awarded to Charleroi by the arbiter"]
      end

      # A team whose match was decided on its boards shows no such line.
      antwerp = Enum.find(payload["teams"], &(&1["name"] == "Antwerp Knights"))
      document = conn |> get(~p"/t/forfeit-present/team/#{antwerp["no"]}") |> doc()
      assert texts(document, ".match-forfeit") == []
    end

    test "present, in Dutch and in French", %{conn: conn, team_rr: payload} do
      ingest!(forfeit_payload(payload, "forfeit-locales", %{"to" => charleroi(payload)["no"]}))

      nl = conn |> get(~p"/t/forfeit-locales/round/1?lang=nl") |> doc()
      assert texts(nl, ".match-forfeit") == ["Door de arbiter toegekend aan Charleroi"]

      fr = conn |> get(~p"/t/forfeit-locales/round/1?lang=fr") |> doc()
      assert texts(fr, ".match-forfeit") == ["Attribué à Charleroi par l'arbitre"]
    end

    test "null: a match decided on its boards says nothing",
         %{conn: conn, team_rr: payload} do
      ingest!(forfeit_payload(payload, "forfeit-null", nil))

      html = conn |> get(~p"/t/forfeit-null/round/1") |> html_response(200)
      refute html =~ "match-forfeit"
      refute html =~ "Awarded to"
    end

    test "absent: an older publisher's payload renders as before", %{conn: conn, team_rr: payload} do
      ingest!(forfeit_payload(payload, "forfeit-absent", :absent))

      html = conn |> get(~p"/t/forfeit-absent/round/1") |> html_response(200)
      assert html =~ "table class=\"matches\""
      refute html =~ "Awarded to"

      html =
        conn |> get(~p"/t/forfeit-absent/team/#{charleroi(payload)["no"]}") |> html_response(200)

      refute html =~ "Awarded to"
    end

    test "withheld: results not public, so neither the score nor the decision shows",
         %{conn: conn, team_rr: payload} do
      withhold = fn round ->
        round
        |> Map.put("results_public", false)
        |> Map.update!("matches", fn matches ->
          Enum.map(matches, &Map.merge(&1, %{"game_points" => nil, "match_points" => nil}))
        end)
      end

      ingest!(forfeit_payload(payload, "forfeit-withheld", nil, withhold))

      html =
        conn
        |> get(~p"/t/forfeit-withheld/team/#{charleroi(payload)["no"]}")
        |> html_response(200)

      assert html =~ "not yet published"
      refute html =~ "Awarded to"

      # A payload that broke the promise - a decision without match points -
      # is not half-shown either.
      broken = fn round ->
        withhold.(round)
        |> Map.update!("matches", fn ms ->
          Enum.map(ms, &Map.put(&1, "forfeit_decision", %{"to" => charleroi(payload)["no"]}))
        end)
      end

      ingest!(forfeit_payload(payload, "forfeit-broken", :absent, broken))

      html =
        conn |> get(~p"/t/forfeit-broken/team/#{charleroi(payload)["no"]}") |> html_response(200)

      refute html =~ "Awarded to"
    end
  end

  describe "GET /t/:slug/board-prizes" do
    test "one table per board", %{conn: conn, rr_slug: slug} do
      document = conn |> get(~p"/t/#{slug}/board-prizes") |> doc()
      assert texts(document, "h3") |> Enum.any?(&String.contains?(&1, "Board"))
    end
  end

  describe "a team Swiss that has not scheduled a match yet" do
    test "the tournament page says there are no team standings yet", %{
      conn: conn,
      team_swiss_slug: slug
    } do
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)
      assert html =~ "No team standings have been published"
    end

    test "a round page carries no matches table", %{conn: conn, team_swiss_slug: slug} do
      html = conn |> get(~p"/t/#{slug}/round/1") |> html_response(200)
      refute html =~ "table class=\"matches\""
    end

    test "offers no team cross-table", %{conn: conn, team_swiss_slug: slug} do
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)
      refute html =~ "Team cross-table"
    end
  end

  describe "an individual tournament" do
    test "shows none of the team pages or links", %{conn: conn, swiss_slug: slug} do
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)
      refute html =~ "Team standings"
      refute html =~ "/board-prizes"
      refute html =~ "Team cross-table"

      conn |> get(~p"/t/#{slug}/team/1") |> html_response(404)
    end
  end
end
