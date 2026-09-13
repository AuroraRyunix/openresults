defmodule OpenResults.ModerationPanelQueriesTest do
  @moduledoc """
  The read functions the admin panel needed beyond the contract's first list:
  the dashboard's counts, what publishing costs in disk, a tournament's
  publishing record, one report, and a block validated before it is stored.
  Each is in `docs/public-publishing.md`, "Moderation API", marked settled in
  the build.
  """

  # Not async, like ModerationTest: status changes write node-wide caches.
  use OpenResults.DataCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.Registrations
  alias OpenResults.Reports
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  @actor %{email: "moderator@example.invalid"}

  defp published_by_installation(installation) do
    slug = mint!(installation)
    {:ok, _} = Snapshots.ingest(payload(slug), installation: installation, key: random_key())
    slug
  end

  defp stored_bytes(slug) do
    slug
    |> Snapshots.history()
    |> Enum.map(fn snapshot ->
      [[bytes]] =
        Repo.query!("SELECT length(CAST(payload AS BLOB)) FROM snapshots WHERE id = ?", [
          snapshot.id
        ]).rows

      bytes
    end)
    |> Enum.sum()
  end

  describe "counts/0" do
    test "every status is present, zero included" do
      assert Moderation.counts() == %{
               installations: %{active: 0, suspended: 0, revoked: 0},
               tournaments: %{pending: 0, listed: 0, hidden: 0},
               open_reports: 0,
               address_blocks: 0
             }
    end

    test "counts installations and tournaments by status, open reports and live blocks" do
      {one, _} = installation!()
      {two, _} = installation!()
      {three, _} = installation!()
      {:ok, _} = Moderation.suspend(two.id, @actor)
      {:ok, _} = Moderation.revoke(three.id, @actor, hide_tournaments: false)

      pending = published_by_installation(one)
      listed = published_by_installation(one)
      {:ok, _} = Moderation.approve(listed, @actor)
      hidden = published_by_installation(one)
      {:ok, _} = Moderation.hide(hidden, @actor)

      {:ok, _} = Reports.create(pending, %{"reason" => "other"}, nil)
      {:ok, resolved} = Reports.create(pending, %{"reason" => "other"}, nil)
      {:ok, _} = Moderation.resolve_report(resolved.id, "fine", @actor)

      {:ok, _} =
        Moderation.block_address(
          "203.0.113.0/24",
          DateTime.add(DateTime.utc_now(), 3600),
          "x",
          @actor
        )

      assert Moderation.counts() == %{
               installations: %{active: 1, suspended: 1, revoked: 1},
               tournaments: %{pending: 1, listed: 1, hidden: 1},
               open_reports: 1,
               address_blocks: 1
             }
    end
  end

  describe "storage" do
    test "server-wide: every stored version's payload bytes, the versions and the tournaments" do
      empty = Moderation.storage()
      assert %{snapshots: 0, snapshot_bytes: 0, tournaments: 0} = empty
      assert is_integer(empty.database_bytes) and empty.database_bytes > 0

      a = unique_slug()
      b = unique_slug()
      {:ok, _} = Snapshots.ingest(payload(a))
      {:ok, _} = Snapshots.ingest(SnapshotPayloads.republished(payload(a)))
      {:ok, _} = Snapshots.ingest(payload(b))

      storage = Moderation.storage()

      assert storage.snapshots == 3
      assert storage.tournaments == 2
      assert storage.snapshot_bytes == stored_bytes(a) + stored_bytes(b)
      # Bytes, not characters: the fixture's names are not all ASCII-free of
      # accents, and a payload is several kilobytes.
      assert storage.snapshot_bytes > 3 * 1_000
    end

    test "per installation: the tournaments it owns now, a transfer moving them" do
      {one, _} = installation!()
      {two, _} = installation!()
      slug = published_by_installation(one)
      _unpublished = mint!(one)

      assert Moderation.installation_storage(one.id) == %{
               tournaments: 1,
               snapshots: 1,
               snapshot_bytes: stored_bytes(slug)
             }

      assert Moderation.installation_storage(two.id) == %{
               tournaments: 0,
               snapshots: 0,
               snapshot_bytes: 0
             }

      {:ok, _} = Moderation.transfer(slug, two.id, @actor)

      assert %{snapshots: 0} = Moderation.installation_storage(one.id)
      assert %{snapshots: 1, tournaments: 1} = Moderation.installation_storage(two.id)
      assert Moderation.installation_storage("in_nobody").snapshots == 0
    end
  end

  describe "tournament_stats/1" do
    test "first and last publish, versions, bytes and waiting entries" do
      slug = unique_slug()
      {:ok, first} = Snapshots.ingest(payload(slug))
      {:ok, last} = Snapshots.ingest(SnapshotPayloads.republished(payload(slug)))

      {:ok, _} =
        Registrations.ingest(Map.put(SnapshotPayloads.registration(), "tournament_slug", slug))

      stats = Moderation.tournament_stats(slug)

      assert stats.snapshots == 2
      assert stats.snapshot_bytes == stored_bytes(slug)
      assert stats.first_published_at == first.received_at
      assert stats.last_published_at == last.received_at
      assert stats.registrations == 1

      [[current]] =
        Repo.query!("SELECT length(CAST(payload AS BLOB)) FROM snapshots WHERE id = ?", [last.id]).rows

      assert stats.current_bytes == current
    end

    test "a slug with nothing published" do
      assert Moderation.tournament_stats("nothing-here") == %{
               snapshots: 0,
               snapshot_bytes: 0,
               current_bytes: nil,
               first_published_at: nil,
               last_published_at: nil,
               registrations: 0
             }
    end
  end

  describe "get_report/1" do
    test "one report by id, whatever form the id arrives in, or nil" do
      {:ok, report} = Reports.create(unique_slug(), %{"reason" => "personal_data"}, nil)

      assert Moderation.get_report(report.id).id == report.id
      assert Moderation.get_report(Integer.to_string(report.id)).id == report.id
      assert Moderation.get_report("not-an-id") == nil
      assert Moderation.get_report(999_999) == nil
    end
  end

  describe "change_block/4" do
    test "validates like block_address/4, normalises the range, and stores nothing" do
      expires = DateTime.add(DateTime.utc_now(), 86_400)

      changeset = Moderation.change_block("203.0.113.77/24", expires, " flood ", @actor)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :cidr) == "203.0.113.0/24"
      assert Moderation.list_blocks() == []
      assert Repo.all(Action) == []
    end

    test "carries the same errors block_address/4 would refuse with" do
      now = DateTime.utc_now()

      for {cidr, expires, reason, field} <- [
            {"not an address", DateTime.add(now, 3600), "x", :cidr},
            {"203.0.113.1", DateTime.add(now, 31 * 86_400), "x", :expires_at},
            {"203.0.113.1", DateTime.add(now, -60), "x", :expires_at},
            {"203.0.113.1", nil, "x", :expires_at},
            {"203.0.113.1", DateTime.add(now, 3600), "   ", :reason}
          ] do
        changeset = Moderation.change_block(cidr, expires, reason, @actor)

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, field), inspect({cidr, field})

        assert {:error, %Ecto.Changeset{}} =
                 Moderation.block_address(cidr, expires, reason, @actor)
      end
    end

    test "needs an actor like everything else here" do
      assert_raise ArgumentError, fn -> Moderation.change_block("203.0.113.1", nil, "x", nil) end
    end
  end
end
