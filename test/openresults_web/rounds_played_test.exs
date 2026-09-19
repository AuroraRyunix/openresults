defmodule OpenResultsWeb.RoundsPlayedTest do
  @moduledoc """
  The optional attendance column, `standings.rows[].rounds_played`.

  A club championship that gives a prize for turning up to every round asked
  for it (2026-09-19). The arbiter's app decides what counts and whether it
  travels at all; this site's whole job is to print the number when it is
  there and to change nothing when it is not - the ordinary additive-field
  rule in docs/snapshot-schema.md.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp with_rounds_played(payload) do
    update_in(payload, ["standings", "rows"], fn rows ->
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, i} -> Map.put(row, "rounds_played", 5 - i) end)
    end)
  end

  test "the column and its numbers appear when the field travels", %{conn: conn} do
    slug = SnapshotPayloads.swiss() |> with_rounds_played() |> publish()

    html = conn |> get(~p"/t/#{slug}") |> html_response(200)

    assert html =~ "Rds"
    assert html =~ "Rounds this player was there for"
    assert html =~ ">5<"
  end

  test "a payload without the field renders exactly as before", %{conn: conn} do
    slug = publish(SnapshotPayloads.swiss())

    html = conn |> get(~p"/t/#{slug}") |> html_response(200)

    refute html =~ "Rounds this player was there for"
  end

  test "a Keizer ladder carries it too", %{conn: conn} do
    slug = SnapshotPayloads.keizer() |> with_rounds_played() |> publish()

    html = conn |> get(~p"/t/#{slug}") |> html_response(200)

    assert html =~ "Rounds this player was there for"
  end
end
