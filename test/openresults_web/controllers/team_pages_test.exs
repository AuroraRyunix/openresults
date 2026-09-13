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
      assert texts(document, ".filter-field") |> Enum.any?(&(&1 =~ "Team"))
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
