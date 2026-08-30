defmodule OpenResults.SnapshotCacheTest do
  @moduledoc """
  One decode per published version, rather than one per reader.

  Revalidation already makes an unchanged poll nearly free. This is for the
  moment it cannot help: a round finishes, the arbiter publishes, and every
  phone in the hall asks for the new page inside the next twenty seconds.
  Those are all genuine 200s for the same document.
  """
  use OpenResults.DataCase, async: false

  alias OpenResults.{SnapshotPayloads, Snapshots}

  setup do
    Snapshots.clear_cache()
    on_exit(&Snapshots.clear_cache/0)

    swiss = SnapshotPayloads.swiss()
    {:ok, snapshot} = Snapshots.ingest(swiss)
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"], snapshot: snapshot}
  end

  test "a repeat read returns the same document", %{slug: slug, snapshot: snapshot} do
    assert Snapshots.latest(slug).id == snapshot.id
    assert Snapshots.latest(slug).id == snapshot.id
    assert Snapshots.latest(slug).payload == snapshot.payload
  end

  test "a new publish is picked up on the next read, with nothing to invalidate", %{
    slug: slug,
    swiss: swiss
  } do
    # The whole safety property. The cache is keyed by slug and VALIDATED by
    # id, so a stale entry cannot outlive the publish that replaced it - no
    # invalidation call to forget, and no window in which a spectator is
    # handed the previous round's standings.
    first = Snapshots.latest(slug)

    changed = put_in(swiss, ["standings", "after_round"], 4)
    {:ok, published} = Snapshots.ingest(changed)

    second = Snapshots.latest(slug)

    assert second.id == published.id
    refute second.id == first.id
    assert second.payload["standings"]["after_round"] == 4
  end

  test "an unknown slug is nil and caches nothing", %{} do
    refute Snapshots.latest("nope")
    refute Snapshots.latest("nope")
  end

  test "a cleared cache rebuilds rather than returning nil", %{slug: slug} do
    assert Snapshots.latest(slug)
    Snapshots.clear_cache()
    assert Snapshots.latest(slug)
  end

  test "the byte-identical re-send that store/3 collapses keeps the same entry", %{
    slug: slug,
    swiss: swiss
  } do
    # A publish that changed nothing does not insert a row, so the id does
    # not move and the cached document stays valid - which is the behaviour
    # that makes a retry after a timeout free rather than expensive.
    first = Snapshots.latest(slug)
    {:ok, _} = Snapshots.ingest(swiss)

    assert Snapshots.latest(slug).id == first.id
  end
end
