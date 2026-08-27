defmodule OpenResultsWeb.SnapshotControllerTest do
  # Not async: the unconfigured-token test moves application env, which is
  # global. ExUnit runs synchronous cases after the async ones have finished.
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  @token "test-ingest-token"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "content-type", "application/json")}
  end

  defp authed_get(path) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
  end

  defp publish(conn, payload, token \\ @token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> post(~p"/api/snapshots", Jason.encode!(payload))
  end

  defp slug_of(payload), do: payload["tournament"]["slug"]

  describe "POST /api/snapshots authentication" do
    test "refuses a request with no authorization header", %{conn: conn} do
      conn = post(conn, ~p"/api/snapshots", Jason.encode!(SnapshotPayloads.swiss()))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert Snapshots.list_current() == []
    end

    test "refuses a wrong token", %{conn: conn} do
      conn = publish(conn, SnapshotPayloads.swiss(), "not-the-token")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert Snapshots.list_current() == []
    end

    test "refuses a token that is a prefix of the real one", %{conn: conn} do
      # The comparison is over fixed-length digests, so neither a prefix nor a
      # length difference tells the caller anything.
      conn = publish(conn, SnapshotPayloads.swiss(), String.slice(@token, 0..3))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "refuses a header that is not a bearer scheme", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic #{Base.encode64("user:#{@token}")}")
        |> post(~p"/api/snapshots", Jason.encode!(SnapshotPayloads.swiss()))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "refuses an empty bearer token", %{conn: conn} do
      conn = publish(conn, SnapshotPayloads.swiss(), "")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "accepts the scheme in any case, as RFC 7235 requires", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "bearer #{@token}")
        |> post(~p"/api/snapshots", Jason.encode!(SnapshotPayloads.swiss()))

      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    test "refuses everything when the server has no token configured", %{conn: conn} do
      configured = Application.get_env(:openresults, :ingest_token)
      Application.put_env(:openresults, :ingest_token, nil)
      on_exit(fn -> Application.put_env(:openresults, :ingest_token, configured) end)

      conn = publish(conn, SnapshotPayloads.swiss())

      # Fails closed, and with the same body as a wrong token: a caller must
      # not be able to tell "wrong token" from "no token set".
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end

  describe "POST /api/snapshots" do
    test "stores a published snapshot", %{conn: conn} do
      payload = SnapshotPayloads.swiss()
      conn = publish(conn, payload)

      assert %{"status" => "ok", "slug" => slug, "received_at" => received_at} =
               json_response(conn, 200)

      assert slug == slug_of(payload)
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(received_at)
      assert Snapshots.latest(slug).payload == payload
    end

    test "stores a keizer snapshot", %{conn: conn} do
      payload = SnapshotPayloads.keizer()
      conn = publish(conn, payload)

      assert json_response(conn, 200)
      assert Snapshots.latest(slug_of(payload)).payload == payload
    end

    test "a payload from a newer OpenPairings is stored, not rejected", %{conn: conn} do
      # The headline guarantee of docs/snapshot-schema.md: a laptop running a
      # version this server has never met publishes fields this server has
      # never heard of, and gets a 200. If this test ever goes red, an arbiter
      # mid-tournament is the one who finds out.
      payload = SnapshotPayloads.swiss() |> SnapshotPayloads.from_the_future()

      conn = publish(conn, payload)

      assert %{"status" => "ok"} = json_response(conn, 200)

      stored = Snapshots.latest(slug_of(payload)).payload
      assert stored == payload
      assert stored["broadcast"] == %{"lichess" => "abcd1234"}
      assert stored["tournament"]["time_control"] == "90+30"
      assert hd(stored["players"])["birth_year"] == 1990
    end

    test "the unknown fields survive the round trip out again", %{conn: conn} do
      payload = SnapshotPayloads.swiss() |> SnapshotPayloads.from_the_future()

      publish(conn, payload)

      read_back = get(build_conn(), ~p"/api/tournaments/#{slug_of(payload)}")

      assert json_response(read_back, 200) == payload
    end

    test "query-string parameters do not leak into the stored document", %{conn: conn} do
      payload = SnapshotPayloads.swiss()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> post(~p"/api/snapshots?injected=nonsense", Jason.encode!(payload))

      assert json_response(conn, 200)
      # The document is what the arbiter's machine built, not what the URL said.
      assert Snapshots.latest(slug_of(payload)).payload == payload
    end

    test "rejects a wrong schema", %{conn: conn} do
      payload = Map.put(SnapshotPayloads.swiss(), "schema", "something/else")
      conn = publish(conn, payload)

      assert %{"error" => "wrong_schema"} = json_response(conn, 422)
    end

    test "rejects an unknown version", %{conn: conn} do
      payload = Map.put(SnapshotPayloads.swiss(), "version", 2)
      conn = publish(conn, payload)

      assert %{"error" => "unknown_version"} = json_response(conn, 422)
    end

    test "rejects a missing slug", %{conn: conn} do
      payload = Map.delete(SnapshotPayloads.swiss(), "tournament")
      conn = publish(conn, payload)

      assert %{"error" => "missing_slug"} = json_response(conn, 422)
    end

    test "rejects a body that is a JSON array", %{conn: conn} do
      conn = publish(conn, [SnapshotPayloads.swiss()])

      assert %{"error" => "wrong_schema"} = json_response(conn, 422)
    end

    test "rejects malformed JSON", %{conn: conn} do
      # Parsing happens in the endpoint, before the router and so before the
      # token gate; the 400 comes from Plug.Parsers and never reaches a
      # controller.
      assert_error_sent 400, fn ->
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> post(~p"/api/snapshots", "{\"schema\": ")
      end
    end
  end

  describe "GET /api/tournaments/:slug" do
    test "returns the stored payload verbatim", %{conn: conn} do
      payload = SnapshotPayloads.swiss()
      publish(conn, payload)

      read_back = get(build_conn(), ~p"/api/tournaments/#{slug_of(payload)}")

      assert json_response(read_back, 200) == payload
    end

    test "needs no token, because a snapshot holds nothing that was withheld" do
      payload = SnapshotPayloads.keizer()
      publish(put_req_header(build_conn(), "content-type", "application/json"), payload)

      read_back = get(build_conn(), ~p"/api/tournaments/#{slug_of(payload)}")

      assert json_response(read_back, 200) == payload
    end

    test "returns the newest publish", %{conn: conn} do
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.republished(first)

      publish(conn, first)
      publish(put_req_header(build_conn(), "content-type", "application/json"), second)

      read_back = get(build_conn(), ~p"/api/tournaments/#{slug_of(first)}")

      assert json_response(read_back, 200) == second
    end

    test "the open route REFUSES `at` rather than quietly serving the present" do
      # Withholding holds for the CURRENT document only. The table is
      # append-only, so an earlier row can hold a round the arbiter has since
      # retracted - a wrong result entered and republished without it - or a
      # board they have since hidden. Serving those by timestamp on an open
      # endpoint hands back exactly what was withdrawn.
      #
      # Refused rather than ignored: answering a question about 14:00 with a
      # document about 18:00, without saying so, leaves the caller no way to
      # notice.
      first = SnapshotPayloads.swiss()
      {:ok, _} = Snapshots.ingest(first, received_at: ~U[2026-03-02 14:00:00.000000Z])

      conn = get(build_conn(), ~p"/api/tournaments/#{slug_of(first)}?at=2026-03-02T16:00:00Z")

      assert %{"error" => "history_requires_auth"} = json_response(conn, 403)
    end

    test "a retracted round is not reachable through the open route" do
      # The concrete breach, pinned. Publish, retract, republish, then try
      # every open way back to what was withdrawn. This is the same failure
      # OpenPairings shipped this week - a backup restoring hidden boards into
      # view - and it must not return through this door.
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.republished(first)
      slug = slug_of(first)

      {:ok, _} = Snapshots.ingest(first, received_at: ~U[2026-03-02 14:00:00.000000Z])
      {:ok, _} = Snapshots.ingest(second, received_at: ~U[2026-03-02 18:00:00.000000Z])

      assert json_response(get(build_conn(), ~p"/api/tournaments/#{slug}"), 200) == second

      for at <- ["2026-03-02T16:00:00Z", "2026-03-02T14:00:00Z", "1970-01-01T00:00:00Z"] do
        conn = get(build_conn(), ~p"/api/tournaments/#{slug}?at=#{at}")
        refute json_response(conn, 403) == first
      end
    end

    test "history serves an earlier snapshot, but only with a token" do
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.republished(first)
      slug = slug_of(first)

      {:ok, _} = Snapshots.ingest(first, received_at: ~U[2026-03-02 14:00:00.000000Z])
      {:ok, _} = Snapshots.ingest(second, received_at: ~U[2026-03-02 18:00:00.000000Z])

      early = authed_get(~p"/api/tournaments/#{slug}/history?at=2026-03-02T16:00:00Z")
      late = authed_get(~p"/api/tournaments/#{slug}/history?at=2026-03-02T20:00:00Z")
      before = authed_get(~p"/api/tournaments/#{slug}/history?at=2026-03-01T00:00:00Z")

      assert json_response(early, 200) == first
      assert json_response(late, 200) == second
      assert %{"error" => "not_found"} = json_response(before, 404)
    end

    test "history without a token is refused" do
      first = SnapshotPayloads.swiss()
      {:ok, _} = Snapshots.ingest(first, received_at: ~U[2026-03-02 14:00:00.000000Z])
      path = ~p"/api/tournaments/#{slug_of(first)}/history?at=2026-03-02T16:00:00Z"

      assert get(build_conn(), path).status == 401

      assert build_conn()
             |> put_req_header("authorization", "Bearer wrong")
             |> get(path)
             |> Map.fetch!(:status) == 401
    end

    test "history rejects an `at` that is not an instant" do
      assert %{"error" => "bad_at"} =
               json_response(authed_get(~p"/api/tournaments/whatever/history?at=teatime"), 400)
    end

    test "history with no `at` at all is a bad request, not the newest document" do
      assert %{"error" => "bad_at"} =
               json_response(authed_get(~p"/api/tournaments/whatever/history"), 400)
    end

    test "404s a tournament that has never published", %{conn: conn} do
      conn = get(conn, ~p"/api/tournaments/no-such-open-2026")

      assert %{"error" => "not_found", "slug" => "no-such-open-2026"} = json_response(conn, 404)
    end
  end
end
