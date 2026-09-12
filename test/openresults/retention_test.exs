defmodule OpenResults.RetentionTest do
  @moduledoc """
  The functions the daily job calls, called directly with a clock. The timer
  itself is `OpenResults.Retention.Scheduler` and is not what is being tested.
  """

  use OpenResults.DataCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.AddressBlocks
  alias OpenResults.Installations
  alias OpenResults.Installations.Installation
  alias OpenResults.Moderation
  alias OpenResults.Reports
  alias OpenResults.Reports.Report
  alias OpenResults.Retention
  alias OpenResults.Snapshots
  alias OpenResults.Tournaments

  @now ~U[2026-09-12 03:00:00.000000Z]

  defp days_ago(days), do: DateTime.add(@now, -days * 86_400)

  defp backdate(schema, id, fields),
    do: Repo.get!(schema, id) |> Ecto.Changeset.change(fields) |> Repo.update!()

  test "keeps thirty days" do
    assert Retention.days() == 30
  end

  test "nulls installation and report addresses older than thirty days, each by its own timestamp" do
    {:ok, %{installation: old}} = Installations.register(%{}, {192, 0, 2, 1})

    backdate(Installation, old.id,
      inserted_at: days_ago(31),
      last_seen_at: days_ago(2),
      last_seen_from: "192.0.2.9"
    )

    {:ok, %{installation: recent}} = Installations.register(%{}, {192, 0, 2, 2})

    backdate(Installation, recent.id,
      inserted_at: days_ago(29),
      last_seen_at: days_ago(40),
      last_seen_from: "192.0.2.8"
    )

    {:ok, old_report} = Reports.create("a-slug", %{"reason" => "other"}, {192, 0, 2, 3})
    backdate(Report, old_report.id, inserted_at: days_ago(31))
    {:ok, new_report} = Reports.create("a-slug", %{"reason" => "other"}, {192, 0, 2, 4})
    backdate(Report, new_report.id, inserted_at: days_ago(1))

    assert Retention.null_old_addresses(@now) == 3

    assert %{created_from: nil, last_seen_from: "192.0.2.9"} = Repo.get!(Installation, old.id)
    assert %{created_from: "192.0.2.2", last_seen_from: nil} = Repo.get!(Installation, recent.id)
    assert %{client_address: nil} = Repo.get!(Report, old_report.id)
    assert %{client_address: "192.0.2.4"} = Repo.get!(Report, new_report.id)

    assert Retention.null_old_addresses(@now) == 0
  end

  test "releases minted slugs with no publish after thirty days" do
    {installation, _} = installation!()
    {:ok, %{slug: stale}} = Tournaments.mint(installation, now: days_ago(31))
    {:ok, %{slug: young}} = Tournaments.mint(installation, now: days_ago(29))
    {:ok, %{slug: used}} = Tournaments.mint(installation, now: days_ago(60))
    {:ok, _} = Snapshots.ingest(payload(used), installation: installation, key: random_key())

    assert Retention.release_unpublished_slugs(@now) == [stale]
    assert Tournaments.get(stale) == nil
    assert Tournaments.get(young)
    assert Tournaments.get(used)
  end

  test "removes expired address blocks and nothing else" do
    {:ok, _} =
      AddressBlocks.create("192.0.2.0/24", DateTime.add(@now, -1), "x", "a@b.c", days_ago(2))

    {:ok, live} =
      AddressBlocks.create("198.51.100.0/24", DateTime.add(@now, 60), "x", "a@b.c", days_ago(2))

    assert Retention.remove_expired_blocks(@now) == 1
    assert [%{id: id}] = AddressBlocks.list_active(@now)
    assert id == live.id
  end

  test "run/1 does all three and logs one retention entry when something changed" do
    assert %{addresses_nulled: 0, slugs_released: [], blocks_removed: 0} = Retention.run(@now)
    assert Moderation.list_actions(actor: "retention") == []

    {installation, _} = installation!()
    {:ok, %{slug: stale}} = Tournaments.mint(installation, now: days_ago(45))

    assert %{slugs_released: [^stale]} = Retention.run(@now)

    assert [%{actor: "retention", action: "retention", details: %{"slugs_released" => [^stale]}}] =
             Moderation.list_actions(actor: "retention")
  end
end
