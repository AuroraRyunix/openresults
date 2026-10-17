defmodule OpenResultsWeb.SexColumnTest do
  @moduledoc """
  The optional Sex column, `players[].sex`.

  OpenPairings sends "M" or "F" only when the arbiter ticked "Sex", which is
  off by default. This site prints the column when the players carry it and
  changes nothing when they do not - the ordinary additive-field rule in
  docs/snapshot-schema.md.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp with_sex(payload) do
    update_in(payload, ["players"], fn players ->
      players
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> Map.put(p, "sex", if(rem(i, 2) == 0, do: "M", else: "F")) end)
    end)
  end

  defp no_rounds(payload) do
    payload
    |> Map.put("rounds", [])
    |> put_in(["standings", "after_round"], 0)
    |> put_in(["standings", "rows"], [])
  end

  test "the standings and the players list carry a Sex column when the field travels", %{
    conn: conn
  } do
    payload = with_sex(SnapshotPayloads.swiss())
    slug = publish(payload)
    assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "col-sex"

    slug = publish(payload |> no_rounds() |> put_in(["tournament", "slug"], "sex-start"))
    html = conn |> get(~p"/t/#{slug}") |> html_response(200)
    assert html =~ "starting-rank"
    assert html =~ ">Sex<"
  end

  test "a payload without the field has no column anywhere", %{conn: conn} do
    payload = SnapshotPayloads.swiss()
    slug = publish(payload)
    refute conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "col-sex"

    slug = publish(payload |> no_rounds() |> put_in(["tournament", "slug"], "sex-start"))
    html = conn |> get(~p"/t/#{slug}") |> html_response(200)
    assert html =~ "starting-rank"
    refute html =~ ">Sex<"
  end
end
