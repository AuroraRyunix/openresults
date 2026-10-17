defmodule OpenResultsWeb.PerformanceColumnTest do
  @moduledoc """
  The optional Performance column, `standings.rows[].performance`.

  OpenPairings sends an integer per row only when the arbiter ticked
  "Performance" (off by default). This site prints the column when any row
  carries it and changes nothing otherwise.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp with_performance(payload) do
    update_in(payload, ["standings", "rows"], fn rows ->
      rows |> Enum.with_index() |> Enum.map(fn {r, i} -> Map.put(r, "performance", 2400 - i) end)
    end)
  end

  test "the standings carry a Perf. column and the numbers when the rows have them", %{
    conn: conn
  } do
    payload = with_performance(SnapshotPayloads.swiss())
    slug = publish(payload)
    html = conn |> get(~p"/t/#{slug}") |> html_response(200)

    assert html =~ "col-perf"
    assert html =~ ~r/col-perf">\s*2400\s*</
  end

  test "a row without the key gets a dash while the others show a number", %{conn: conn} do
    payload =
      SnapshotPayloads.swiss()
      |> with_performance()
      |> update_in(["standings", "rows"], fn [first | rest] ->
        [Map.delete(first, "performance") | rest]
      end)

    slug = publish(payload)
    html = conn |> get(~p"/t/#{slug}") |> html_response(200)
    assert html =~ "col-perf"
    refute html =~ ~r/col-perf">\s*2400\s*</
  end

  test "a payload without the key has no column", %{conn: conn} do
    slug = publish(SnapshotPayloads.swiss())
    refute conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "col-perf"
  end
end
