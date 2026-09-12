defmodule OpenResults.SnapshotLatestIdTest do
  @moduledoc """
  `Snapshots.latest_id/1` is the one query `Plugs.Revalidate` used to run on
  every single request - see `docs/load-test-2026-09-12.md` §5. These tests
  are about the cache in front of it, not about `ingest/2` itself (already
  covered by `OpenResults.SnapshotsTest`): a hit that never touches the
  database, a miss that falls back and remembers, a publish that is visible
  to the very next caller with nothing to invalidate by hand, and a takedown
  that leaves no stale id behind it.

  Not async, like `OpenResults.SnapshotCacheTest` next to it: the cache is
  one shared, named ETS table, and these tests reach into it directly.
  """
  use OpenResults.DataCase, async: false

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResults.Snapshots.LatestIdCache

  setup do
    Snapshots.clear_cache()
    on_exit(&Snapshots.clear_cache/0)

    swiss = SnapshotPayloads.swiss()
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  describe "a cache hit" do
    test "is trusted outright, even against what the database actually holds", %{
      slug: slug,
      swiss: swiss
    } do
      {:ok, snapshot} = Snapshots.ingest(swiss)

      # `store/3` already cached the real id via its write-through. Prove the
      # read path takes the cache's word for it, and not the database's, by
      # making the two disagree directly rather than by mocking anything.
      LatestIdCache.put(slug, snapshot.id + 999)

      assert Snapshots.latest_id(slug) == snapshot.id + 999
    end
  end

  describe "a cache miss" do
    test "falls back to the query and remembers the answer", %{slug: slug, swiss: swiss} do
      {:ok, snapshot} = Snapshots.ingest(swiss)

      # `ingest/2` already primed the cache; force a genuine miss to test the
      # fallback itself, not the write-through that normally prevents it.
      LatestIdCache.forget(slug)
      assert LatestIdCache.fetch(slug) == :miss

      assert Snapshots.latest_id(slug) == snapshot.id
      assert LatestIdCache.fetch(slug) == {:ok, snapshot.id}
    end

    test "an unpublished slug is nil, and nothing is cached for it", %{} do
      refute Snapshots.latest_id("no-such-tournament")
      assert LatestIdCache.fetch("no-such-tournament") == :miss
    end
  end

  describe "an entirely empty table" do
    test "every slug still falls back correctly, independently of the others", %{swiss: swiss} do
      keizer = SnapshotPayloads.keizer()

      {:ok, swiss_snapshot} = Snapshots.ingest(swiss)
      {:ok, keizer_snapshot} = Snapshots.ingest(keizer)

      # A cold cache - a fresh boot, or anything that clears it outright -
      # must not be mistaken for "nothing has ever been published".
      LatestIdCache.clear()

      assert Snapshots.latest_id(swiss["tournament"]["slug"]) == swiss_snapshot.id
      assert Snapshots.latest_id(keizer["tournament"]["slug"]) == keizer_snapshot.id
    end
  end

  describe "a publish" do
    test "is visible to the very next caller, with nothing invalidated by hand", %{
      slug: slug,
      swiss: swiss
    } do
      {:ok, first} = Snapshots.ingest(swiss)
      assert Snapshots.latest_id(slug) == first.id

      changed = put_in(swiss, ["standings", "after_round"], 4)
      {:ok, second} = Snapshots.ingest(changed)

      # The cache itself already carries the new id the instant `ingest/2`
      # returns - not "eventually", not "on the next miss". This is the
      # property a stale 304 would violate.
      assert LatestIdCache.fetch(slug) == {:ok, second.id}
      assert Snapshots.latest_id(slug) == second.id
      refute second.id == first.id
    end

    test "a byte-identical republish leaves the cached id exactly where it was", %{
      slug: slug,
      swiss: swiss
    } do
      {:ok, first} = Snapshots.ingest(swiss)
      {:ok, second} = Snapshots.ingest(swiss)

      assert second.id == first.id
      assert Snapshots.latest_id(slug) == first.id
    end
  end

  describe "a takedown" do
    test "forgets the id along with the rows, rather than leaving it cached", %{
      slug: slug,
      swiss: swiss
    } do
      {:ok, _snapshot} = Snapshots.ingest(swiss)
      assert {:ok, _} = LatestIdCache.fetch(slug)

      assert Snapshots.delete_all_for(slug) == 1

      # The database now holds nothing for this slug. A cache still
      # answering with the id of a row that no longer exists would tell a
      # reader the opposite of the truth.
      assert LatestIdCache.fetch(slug) == :miss
      refute Snapshots.latest_id(slug)
    end
  end
end
