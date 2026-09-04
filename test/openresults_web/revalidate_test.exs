defmodule OpenResultsWeb.RevalidateTest do
  @moduledoc """
  A poll that finds nothing new must cost a primary-key lookup, not half a
  megabyte of JSON - and a poll that finds something new must get it at once.

  The second half is the constraint that shaped this. The maintainer rejected
  CDN caching for exactly the right reason: there is no worse failure for a
  results site than a stuck page somebody trusts. So `no-cache` here means
  "always ask", never "hold this for a while".
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.{SnapshotPayloads, Snapshots}

  setup do
    swiss = SnapshotPayloads.swiss()
    {:ok, snapshot} = Snapshots.ingest(swiss)
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"], snapshot: snapshot}
  end

  defp etag(conn), do: conn |> get_resp_header("etag") |> List.first()

  describe "an unchanged document" do
    test "answers 304 with no body", %{conn: conn, slug: slug} do
      first = get(conn, ~p"/t/#{slug}")
      assert first.status == 200
      tag = etag(first)
      assert tag

      second = build_conn() |> put_req_header("if-none-match", tag) |> get(~p"/t/#{slug}")

      assert second.status == 304
      assert second.resp_body == ""
    end

    test "and is never held: the header says ask again, not keep", %{conn: conn, slug: slug} do
      conn = get(conn, ~p"/t/#{slug}")

      assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
    end

    test "a weak validator from an intermediary still matches", %{conn: conn, slug: slug} do
      tag = conn |> get(~p"/t/#{slug}") |> etag()

      weak = build_conn() |> put_req_header("if-none-match", "W/" <> tag) |> get(~p"/t/#{slug}")

      assert weak.status == 304
    end
  end

  describe "a document that has changed" do
    test "is served immediately, not after any delay", %{conn: conn, slug: slug, swiss: swiss} do
      tag = conn |> get(~p"/t/#{slug}") |> etag()

      # Publish a new version - what an arbiter entering a result causes.
      changed = put_in(swiss, ["standings", "after_round"], 4)
      {:ok, _} = Snapshots.ingest(changed)

      fresh = build_conn() |> put_req_header("if-none-match", tag) |> get(~p"/t/#{slug}")

      assert fresh.status == 200
      assert etag(fresh) != tag
    end
  end

  describe "the identity is the page, not only the tournament" do
    test "moving to a page you have not seen is not 'unchanged'", %{conn: conn, slug: slug} do
      # One document renders as standings, as a round and as a card per
      # player. An ETag naming only the snapshot would tell a reader moving
      # from the standings to a player page that it was unchanged.
      standings = conn |> get(~p"/t/#{slug}") |> etag()

      player =
        build_conn() |> put_req_header("if-none-match", standings) |> get(~p"/t/#{slug}/player/1")

      assert player.status == 200
      assert etag(player) != standings
    end

    test "each page revalidates against its own tag", %{conn: conn, slug: slug} do
      tag = conn |> get(~p"/t/#{slug}/player/1") |> etag()

      again = build_conn() |> put_req_header("if-none-match", tag) |> get(~p"/t/#{slug}/player/1")

      assert again.status == 304
    end

    test "the projector view is a different page too, not the same round again", %{
      conn: conn,
      slug: slug
    } do
      # Same path, different query string. Without the query string in the
      # identity, this tag would also validate the plain round page - and
      # worse, the two would shadow each other in the page cache, so
      # whichever rendered first would be served for both.
      round = conn |> get(~p"/t/#{slug}/round/1") |> etag()

      projector =
        build_conn()
        |> put_req_header("if-none-match", round)
        |> get(~p"/t/#{slug}/round/1?display=1")

      assert projector.status == 200
      assert etag(projector) != round
    end
  end

  describe "what is deliberately left alone" do
    test "the entry form never revalidates", %{conn: conn, slug: slug} do
      # A form is not a document. A browser deciding it already has the
      # answer is exactly wrong here.
      conn = get(conn, ~p"/t/#{slug}/register")

      assert get_resp_header(conn, "etag") == []
    end

    test "an unknown slug gets its 404 rather than a tag", %{conn: conn} do
      conn = get(conn, ~p"/t/nope")

      assert conn.status == 404
      assert get_resp_header(conn, "etag") == []
    end
  end
end
