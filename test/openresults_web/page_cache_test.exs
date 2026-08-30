defmodule OpenResultsWeb.PageCacheTest do
  @moduledoc """
  A publish costs one render and then N sends, rather than N renders.

  Safe only because these pages are byte-identical for every reader: no
  login, no session, no CSRF token in the layout, no locale on the read
  path. The tests that matter are the ones proving a stale page can never
  be served - that is the property CDN caching was rejected to protect, and
  this must not reintroduce it by the back door.
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.Plugs.Revalidate.Page

  setup do
    Snapshots.clear_cache()
    Page.clear()

    on_exit(fn ->
      Snapshots.clear_cache()
      Page.clear()
    end)

    swiss = SnapshotPayloads.swiss()
    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  test "the second reader gets the same bytes as the first", %{conn: conn, slug: slug} do
    first = conn |> get(~p"/t/#{slug}") |> html_response(200)
    second = build_conn() |> get(~p"/t/#{slug}") |> html_response(200)

    assert first == second
  end

  test "a publish makes the stored page unreachable, not merely old", %{
    conn: conn,
    slug: slug,
    swiss: swiss
  } do
    # The property CDN caching was rejected to protect. A new version must
    # never be shadowed by a rendered page from the previous one.
    before = conn |> get(~p"/t/#{slug}") |> html_response(200)
    assert before =~ "after round 3"

    changed = put_in(swiss, ["standings", "after_round"], 4)
    {:ok, _} = Snapshots.ingest(changed)

    now = build_conn() |> get(~p"/t/#{slug}") |> html_response(200)

    assert now =~ "after round 4"
    refute now == before
  end

  test "each page is stored separately, and one never stands in for another", %{
    conn: conn,
    slug: slug
  } do
    standings = conn |> get(~p"/t/#{slug}") |> html_response(200)
    player = build_conn() |> get(~p"/t/#{slug}/player/1") |> html_response(200)

    refute standings == player

    # And each is still itself on a second read.
    assert build_conn() |> get(~p"/t/#{slug}") |> html_response(200) == standings
    assert build_conn() |> get(~p"/t/#{slug}/player/1") |> html_response(200) == player
  end

  test "a 404 is never stored as though it were the document", %{conn: conn} do
    assert conn |> get(~p"/t/nope") |> html_response(404)
    assert build_conn() |> get(~p"/t/nope") |> html_response(404)
  end

  test "a withheld page is not stored either", %{conn: conn, swiss: swiss} do
    # `player_cards` off means the player route answers 404. Storing that
    # against the tournament's version would be storing a refusal.
    hidden =
      swiss
      |> put_in(["tournament", "slug"], "no-cards")
      |> put_in(["tournament", "display", "player_cards"], false)

    {:ok, _} = Snapshots.ingest(hidden)

    assert conn |> get(~p"/t/no-cards/player/1") |> html_response(404)
    assert build_conn() |> get(~p"/t/no-cards") |> html_response(200)
  end

  test "clearing the cache costs a re-render, not correctness", %{conn: conn, slug: slug} do
    first = conn |> get(~p"/t/#{slug}") |> html_response(200)
    Page.clear()

    assert build_conn() |> get(~p"/t/#{slug}") |> html_response(200) == first
  end

  describe "the store itself" do
    test "answers nil for a version it does not hold" do
      assert Page.get(999, ~s("999-1")) == nil
    end

    test "drops everything when the version moves" do
      Page.put(1, ~s("1-a"), "old")
      assert Page.get(1, ~s("1-a")) == "old"

      Page.put(2, ~s("2-a"), "new")

      refute Page.get(1, ~s("1-a"))
      assert Page.get(2, ~s("2-a")) == "new"
    end
  end
end
