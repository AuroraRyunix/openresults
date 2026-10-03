defmodule OpenResultsWeb.TeamWithoutPlayersTest do
  @moduledoc """
  A team event published from OpenPairings with optional line-ups - the
  fixture `snapshot_team_lineups_optional.json`: teams with no players, so
  matches with no board on the page, scored only in their `game_points` and
  the team standings. Every page renders, the matches keep their scores, and
  the team list shows the teams' ratings.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  @slug "team-lineups-optional-fixture"

  setup do
    {:ok, _} = Snapshots.ingest(SnapshotPayloads.team_lineups_optional())
    :ok
  end

  defp doc(conn, path), do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  test "every page of the event renders", %{conn: conn} do
    for path <- [
          ~p"/t/#{@slug}",
          ~p"/t/#{@slug}/round/1",
          ~p"/t/#{@slug}/round/2",
          ~p"/t/#{@slug}/teams",
          ~p"/t/#{@slug}/team/1",
          ~p"/t/#{@slug}/team/2",
          ~p"/t/#{@slug}/team/3",
          ~p"/t/#{@slug}/team/4",
          ~p"/t/#{@slug}/crosstable",
          ~p"/t/#{@slug}/board-prizes"
        ] do
      assert conn |> get(path) |> html_response(200), path
    end
  end

  test "a round's matches keep their scores although no board is on the page", %{conn: conn} do
    document = doc(conn, ~p"/t/#{@slug}/round/1")

    rows = texts(document, "table.matches tbody tr")
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1 =~ "1.5 - 0.5"))
  end

  test "the team list shows the ratings OpenPairings sent", %{conn: conn} do
    document = doc(conn, ~p"/t/#{@slug}/teams")

    assert texts(document, "#team-list thead th") |> Enum.member?("Rating")

    ratings =
      document
      |> LazyHTML.query("#team-list tbody tr")
      |> Enum.map(fn row ->
        name = row |> LazyHTML.query("th") |> LazyHTML.text() |> String.trim()
        cells = row |> LazyHTML.query("td") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
        {name, cells}
      end)
      |> Map.new()

    assert Enum.member?(ratings["Brugse SK"], "2075")
    assert Enum.member?(ratings["Charleroi"], "1950")
    assert Enum.member?(ratings["Deurne"], "-")
  end

  test "a payload without ratings shows no Rating column", %{conn: conn} do
    payload =
      SnapshotPayloads.team_lineups_optional()
      |> put_in(["tournament", "slug"], "team-no-ratings")
      |> Map.update!("teams", fn teams -> Enum.map(teams, &Map.delete(&1, "rating")) end)

    {:ok, _} = Snapshots.ingest(payload)
    document = doc(conn, ~p"/t/team-no-ratings/teams")
    refute texts(document, "#team-list thead th") |> Enum.member?("Rating")
  end
end
