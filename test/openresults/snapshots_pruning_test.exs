defmodule OpenResults.SnapshotsPruningTest do
  @moduledoc """
  The version cap - `docs/public-publishing.md`, "Storage bounds". An
  installation's tournament keeps its newest N versions; the operator's keep
  every one; and nothing a reader can see changes except that versions older
  than the newest N are gone.

  The oracle for "exactly as before" is the same sequence of publishes into a
  second installation tournament with a cap too large to prune: both are
  pending and owned, so the only difference between them is the cap.
  """
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Snapshots

  setup do
    {installation, key} = installation!()
    {:ok, installation: installation, key: key}
  end

  defp put_cap(n) do
    previous = Application.get_env(:openresults, :installation_max_versions)
    Application.put_env(:openresults, :installation_max_versions, n)
    on_exit(fn -> Application.put_env(:openresults, :installation_max_versions, previous) end)
  end

  defp at(minute), do: DateTime.add(~U[2026-09-13 10:00:00.000000Z], minute * 60, :second)

  # Version `n` of a tournament: standings after round n, and from version 4
  # on round 3 retracted (removed) - a wrong result, republished without it.
  defp version(slug, n) do
    base = payload(slug)
    base = put_in(base, ["standings", "after_round"], n)

    if n >= 4,
      do: Map.update!(base, "rounds", fn rounds -> Enum.reject(rounds, &(&1["number"] == 3)) end),
      else: base
  end

  defp publish_sequence(slug, installation, count) do
    tkey = random_key()

    for n <- 1..count do
      {:ok, _} =
        Snapshots.ingest(version(slug, n),
          installation: installation,
          key: tkey,
          received_at: at(n)
        )
    end

    tkey
  end

  test "keeps exactly the newest N, by insertion, and never the current one", %{
    installation: installation
  } do
    put_cap(3)
    slug = mint!(installation)
    publish_sequence(slug, installation, 7)

    kept = Snapshots.history(slug)
    assert length(kept) == 3
    assert Enum.map(kept, & &1.payload["standings"]["after_round"]) == [7, 6, 5]
    assert Snapshots.latest(slug).payload == version(slug, 7)
  end

  test "a cap of 1 or less still keeps the current version", %{installation: installation} do
    slug = mint!(installation)
    publish_sequence(slug, installation, 3)

    for keep <- [1, 0, -5] do
      Snapshots.prune_versions(slug, keep)
      assert [only] = Snapshots.history(slug)
      assert only.payload == version(slug, 3)
    end
  end

  test "the current snapshot, history's newest entries, as_of, withholding and retraction are as before",
       %{installation: installation, key: key} do
    put_cap(3)
    pruned = mint!(installation)
    pruned_tkey = publish_sequence(pruned, installation, 6)

    put_cap(1000)
    whole = mint!(installation)
    publish_sequence(whole, installation, 6)

    strip = fn snapshots -> Enum.map(snapshots, &Map.delete(&1.payload, "tournament")) end

    # Current: the same document, rounds withheld and retracted as published.
    assert strip.([Snapshots.latest(pruned)]) == strip.([Snapshots.latest(whole)])
    refute 3 in Enum.map(Snapshots.latest(pruned).payload["rounds"], & &1["number"])

    # History: the newest three, identical.
    assert strip.(Snapshots.history(pruned)) == strip.(Enum.take(Snapshots.history(whole), 3))

    # as_of: identical from the oldest kept version on; nil before it -
    # never a different document.
    for minute <- 4..8 do
      assert strip.([Snapshots.as_of(pruned, at(minute))]) ==
               strip.([Snapshots.as_of(whole, at(minute))])
    end

    for minute <- 1..3, do: assert(Snapshots.as_of(pruned, at(minute)) == nil)

    # Over HTTP: the public read serves the current document and still refuses
    # `at`; the owner's history answers for a kept instant.
    public = build_conn() |> get("/api/tournaments/#{pruned}") |> json_response(200)
    assert public == Snapshots.latest(pruned).payload

    assert build_conn()
           |> get("/api/tournaments/#{pruned}?at=2026-09-13T10:02:00Z")
           |> json_response(403)
           |> Map.fetch!("error") == "history_requires_auth"

    conn =
      build_conn()
      |> bearer(key)
      |> get("/api/tournaments/#{pruned}/history?at=2026-09-13T10:05:30Z")

    assert json_response(conn, 200)["standings"]["after_round"] == 5
    assert pruned_tkey
  end

  test "an unchanged repeat prunes too, so a lowered cap applies at the next publish", %{
    installation: installation
  } do
    slug = mint!(installation)
    tkey = publish_sequence(slug, installation, 5)
    assert length(Snapshots.history(slug)) == 5

    put_cap(2)
    {:ok, _} = Snapshots.ingest(version(slug, 5), installation: installation, key: tkey)
    assert length(Snapshots.history(slug)) == 2
  end

  test "operator-published tournaments keep every version, and an operator publish never prunes",
       %{installation: installation} do
    put_cap(2)

    operator_slug = unique_slug("operator")

    for n <- 1..5,
        do: {:ok, _} = Snapshots.ingest(version(operator_slug, n), received_at: at(n))

    assert length(Snapshots.history(operator_slug)) == 5

    # An operator publish to an installation's tournament does not prune it.
    slug = mint!(installation)
    put_cap(1000)
    tkey = publish_sequence(slug, installation, 4)
    put_cap(2)

    {:ok, _} = Snapshots.ingest(version(slug, 9), key: tkey)
    assert length(Snapshots.history(slug)) == 5

    # And that installation's next publish does.
    {:ok, _} = Snapshots.ingest(version(slug, 10), installation: installation, key: tkey)
    assert length(Snapshots.history(slug)) == 2
  end

  test "pruning keeps the page-cache and latest-id caches naming a row that exists", %{
    installation: installation
  } do
    put_cap(2)
    slug = mint!(installation)
    publish_sequence(slug, installation, 5)

    newest = Snapshots.latest_id(slug)
    assert Enum.any?(Snapshots.history(slug), &(&1.id == newest))
    assert Snapshots.latest(slug).id == newest
  end
end
