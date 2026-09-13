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
  alias OpenResults.Moderation.Action
  alias OpenResults.Registrations
  alias OpenResults.Registrations.Registration
  alias OpenResults.Reports
  alias OpenResults.Reports.Report
  alias OpenResults.Retention
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.Snapshots.Snapshot
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

  test "run/1 does the original three and logs one retention entry when something changed" do
    assert %{addresses_nulled: 0, slugs_released: [], blocks_removed: 0} = Retention.run(@now)
    assert Moderation.list_actions(actor: "retention") == []

    {installation, _} = installation!()
    {:ok, %{slug: stale}} = Tournaments.mint(installation, now: days_ago(45))

    assert %{slugs_released: [^stale]} = Retention.run(@now)

    assert [%{actor: "retention", action: "retention", details: %{"slugs_released" => [^stale]}}] =
             Moderation.list_actions(actor: "retention")
  end

  describe "registrations" do
    # A tournament published `published_days_ago`, with these dates in its
    # snapshot (nil leaves the field out), holding `entries` registrations.
    defp tournament(dates, published_days_ago, entries \\ 2) do
      slug = unique_slug("reg")

      tournament =
        Enum.reduce(dates, payload(slug)["tournament"], fn
          {field, nil}, acc -> Map.delete(acc, field)
          {field, value}, acc -> Map.put(acc, field, value)
        end)

      {:ok, snapshot} = Snapshots.ingest(Map.put(payload(slug), "tournament", tournament))
      backdate(Snapshot, snapshot.id, received_at: days_ago(published_days_ago))

      for _ <- 1..entries//1 do
        {:ok, _} =
          Registrations.ingest(Map.put(SnapshotPayloads.registration(), "tournament_slug", slug))
      end

      slug
    end

    defp queued(slug), do: length(Registrations.list_for_tournament(slug))

    test "defaults to thirty days" do
      assert Retention.registration_retention_days() == 30
    end

    test "deletes the queue thirty days after the end date, and not a day sooner" do
      over = tournament(%{"end_date" => "2026-08-12", "start_date" => "2026-08-10"}, 1)
      edge = tournament(%{"end_date" => "2026-08-13", "start_date" => nil}, 1, 1)
      young = tournament(%{"end_date" => "2026-08-14", "start_date" => nil}, 90)

      assert Retention.delete_expired_registrations(@now) == 3
      assert queued(over) == 0
      assert queued(edge) == 0
      assert queued(young) == 2
    end

    test "with no end date, judges by the last publish" do
      stale = tournament(%{"end_date" => nil, "start_date" => nil}, 31)
      garbled = tournament(%{"end_date" => "someday", "start_date" => "2026-01-01"}, 30)
      fresh = tournament(%{"end_date" => nil, "start_date" => nil}, 29)

      assert Registrations.delete_expired(@now, 30) == 4
      assert queued(stale) == 0
      assert queued(garbled) == 0
      assert queued(fresh) == 2
    end

    test "a tournament that hasn't happened yet keeps its registrations" do
      upcoming = tournament(%{"end_date" => nil, "start_date" => "2026-10-01"}, 200)

      assert Registrations.delete_expired(@now, 30) == 0
      assert queued(upcoming) == 2
    end

    test "a tournament that never published keeps its queue" do
      slug = unique_slug("never")

      {:ok, registration} =
        Registrations.ingest(Map.put(SnapshotPayloads.registration(), "tournament_slug", slug))

      backdate(Registration, registration.id, received_at: days_ago(400))

      assert Registrations.delete_expired(@now, 30) == 0
      assert queued(slug) == 1
    end
  end

  describe "report contacts" do
    defp report(status, resolved_days_ago) do
      {:ok, report} =
        Reports.create("a-slug", %{"reason" => "other", "contact_email" => "p@example.org"}, nil)

      fields =
        case status do
          "open" ->
            [inserted_at: days_ago(500)]

          "resolved" ->
            [
              status: "resolved",
              resolution: "done",
              resolved_by: "a@b.c",
              resolved_at: days_ago(resolved_days_ago)
            ]
        end

      backdate(Report, report.id, fields)
    end

    test "defaults to ninety days" do
      assert Retention.report_contact_retention_days() == 90
    end

    test "forgets the contact of a report resolved more than ninety days ago" do
      old = report("resolved", 91)
      young = report("resolved", 89)

      assert Retention.forget_old_report_contacts(@now) == 1
      assert %{contact_email: nil, status: "resolved"} = Repo.get!(Report, old.id)
      assert %{contact_email: "p@example.org"} = Repo.get!(Report, young.id)
    end

    test "an unresolved report keeps its contact, however old" do
      open = report("open", nil)

      assert Reports.null_contact_emails_before(@now) == 0
      assert Retention.forget_old_report_contacts(DateTime.add(@now, 3650 * 86_400)) == 0
      assert %{contact_email: "p@example.org"} = Repo.get!(Report, open.id)
    end
  end

  describe "action-log address ranges" do
    defp block_entry(action, details, inserted_at) do
      Repo.insert!(%Action{
        actor: "a@b.c",
        action: action,
        target_type: "address_block",
        target: "1",
        details: details,
        inserted_at: inserted_at
      })
    end

    test "defaults to thirty days" do
      assert Retention.block_address_retention_days() == 30
    end

    test "forgets the range thirty days after the block ended, keeps a younger one" do
      old =
        block_entry(
          "block_address",
          %{"cidr" => "192.0.2.0/24", "expires_at" => DateTime.to_iso8601(days_ago(31))},
          days_ago(40)
        )

      young =
        block_entry(
          "block_address",
          %{"cidr" => "192.0.2.9/32", "expires_at" => DateTime.to_iso8601(days_ago(29))},
          days_ago(40)
        )

      lifted = block_entry("unblock", %{"cidr" => "192.0.2.0/24"}, days_ago(30))

      assert Retention.forget_expired_block_addresses(@now) == 2
      assert %{details: %{"cidr" => nil}} = Repo.get!(Action, old.id)
      assert %{details: %{"cidr" => "192.0.2.9/32"}} = Repo.get!(Action, young.id)
      assert %{details: %{"cidr" => nil}} = Repo.get!(Action, lifted.id)
    end
  end

  describe "run/1 and the three newer rules" do
    test "carries the three new counts, zero when nothing is due" do
      assert %{
               registrations_deleted: 0,
               report_contacts_forgotten: 0,
               block_addresses_forgotten: 0
             } =
               Retention.run(@now)

      assert Moderation.list_actions(actor: "retention") == []
    end

    test "logs a retention entry when only registrations went" do
      tournament(%{"end_date" => "2026-01-01", "start_date" => nil}, 200, 1)
      assert %{registrations_deleted: 1} = Retention.run(@now)

      assert [%{details: %{"registrations_deleted" => 1}}] =
               Moderation.list_actions(actor: "retention")
    end

    test "logs a retention entry when only a report contact went" do
      report("resolved", 120)
      assert %{report_contacts_forgotten: 1} = Retention.run(@now)

      assert [%{details: %{"report_contacts_forgotten" => 1}}] =
               Moderation.list_actions(actor: "retention")
    end

    test "logs a retention entry when only an action-log range went" do
      block_entry("unblock", %{"cidr" => "192.0.2.0/24"}, days_ago(60))
      assert %{block_addresses_forgotten: 1} = Retention.run(@now)

      assert [%{details: %{"block_addresses_forgotten" => 1}}] =
               Moderation.list_actions(actor: "retention")
    end
  end
end
