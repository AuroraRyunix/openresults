defmodule OpenResultsWeb.ManualOrderTest do
  @moduledoc """
  The disclosure that a standings order was set by hand.

  docs/manual-standings.md lists every surface that has to carry it, and
  singles out the public one: it is the page a viewer with no login sees, so
  silence there is the most misleading failure this feature has. That surface
  used to be the arbiter app's own standings page. It was removed on
  2026-08-29, and the duty moved here.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  test "a hand-ordered tournament says so above the table", %{conn: conn} do
    slug =
      SnapshotPayloads.swiss()
      |> put_in(["standings", "manual_order"], true)
      |> publish()

    html = conn |> get(~p"/t/#{slug}") |> html_response(200)

    assert html =~ "set by the arbiter, not computed"
  end

  test "an ordinary tournament says nothing", %{conn: conn} do
    slug =
      SnapshotPayloads.swiss()
      |> put_in(["standings", "manual_order"], false)
      |> publish()

    refute conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "set by the arbiter"
  end

  test "a payload that predates the field says nothing either" do
    # Not "assume hand-ordered". An app that could not tell us has not made a
    # disclosure, and inventing one on its behalf would be this server
    # asserting something about an arbiter it cannot know.
    payload = update_in(SnapshotPayloads.swiss(), ["standings"], &Map.delete(&1, "manual_order"))

    refute OpenResultsWeb.Tournament.manual_order?(payload)
  end

  test "the order itself is untouched by the flag either way" do
    payload = SnapshotPayloads.swiss()
    sent = Enum.map(payload["standings"]["rows"], & &1["rank"])

    for flag <- [true, false] do
      rows =
        payload
        |> put_in(["standings", "manual_order"], flag)
        |> OpenResultsWeb.Tournament.standings_rows()

      assert Enum.map(rows, & &1["rank"]) == sent
    end
  end
end
