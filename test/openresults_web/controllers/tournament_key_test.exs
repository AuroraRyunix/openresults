defmodule OpenResultsWeb.TournamentKeyTest do
  @moduledoc """
  The per-tournament key, and the takedown it makes safe.

  Everything here goes through the HTTP boundary rather than calling the
  contexts, because the header is half of the contract and a context test
  cannot get it wrong.
  """

  # Not async: the break-glass tests read `:ingest_token` from application env,
  # which is global.
  use OpenResultsWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias OpenResults.Registrations
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.TournamentKeys

  @token "test-ingest-token"
  @key "3f1c9a6d4b8e2705aa91cc0d6e5f4318"
  @other_key "beefcafe00112233445566778899aabb"

  setup do
    {:ok, payload: SnapshotPayloads.swiss()}
  end

  defp publish(payload, opts \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{Keyword.get(opts, :token, @token)}")
    |> with_key(Keyword.get(opts, :key))
    |> post(~p"/api/snapshots", Jason.encode!(payload))
  end

  defp takedown(slug, opts \\ []) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{Keyword.get(opts, :token, @token)}")
    |> with_key(Keyword.get(opts, :key))
    |> delete(~p"/api/tournaments/#{slug}")
  end

  defp authed_get(path) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
  end

  defp with_key(conn, nil), do: conn
  defp with_key(conn, key), do: put_req_header(conn, "x-openresults-key", key)

  defp slug_of(payload), do: payload["tournament"]["slug"]

  defp register(slug) do
    payload = SnapshotPayloads.registration() |> Map.put("tournament_slug", slug)
    {:ok, registration} = Registrations.ingest(payload)
    registration
  end

  describe "claiming a slug" do
    test "the first publish carrying a key claims the slug", %{payload: payload} do
      slug = slug_of(payload)

      refute TournamentKeys.claimed?(slug)

      assert %{"status" => "ok"} = json_response(publish(payload, key: @key), 200)

      assert TournamentKeys.claimed?(slug)
      assert Snapshots.latest(slug).payload == payload
    end

    test "the key is stored hashed, and the plaintext is nowhere in the row", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)

      row =
        OpenResults.Repo.get_by(OpenResults.TournamentKeys.TournamentKey, tournament_slug: slug)

      # A dump of this database must not confer publish rights over every
      # tournament that has ever published here.
      assert row.key_hash == TournamentKeys.hash(@key)
      refute row.key_hash == @key
      refute String.contains?(row.key_hash, @key)
    end

    test "a second publish with the same key succeeds", %{payload: payload} do
      slug = slug_of(payload)
      republished = SnapshotPayloads.republished(payload)

      assert %{"status" => "ok"} = json_response(publish(payload, key: @key), 200)
      assert %{"status" => "ok"} = json_response(publish(republished, key: @key), 200)

      assert Snapshots.latest(slug).payload == republished
      assert length(Snapshots.history(slug)) == 2
    end

    test "a publish with the WRONG key is refused and changes nothing", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)

      before = Snapshots.history(slug)

      conn = publish(SnapshotPayloads.republished(payload), key: @other_key)

      assert %{"error" => "key_mismatch"} = json_response(conn, 403)

      # 403, not 401: the caller may talk to this server, just not to this
      # tournament.
      assert conn.status == 403
      assert Snapshots.history(slug) == before
      assert Snapshots.latest(slug).payload == payload
    end

    test "a publish with NO key against a claimed slug is refused", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)

      before = Snapshots.history(slug)

      conn = publish(SnapshotPayloads.republished(payload))

      # The case that makes the whole thing worth having: a claimed tournament
      # must not be takeable over by simply omitting the header.
      assert %{"error" => "key_required"} = json_response(conn, 403)
      assert Snapshots.history(slug) == before
    end

    test "a blank key is treated as no key, and never claims a slug", %{payload: payload} do
      slug = slug_of(payload)

      assert %{"status" => "ok"} = json_response(publish(payload, key: "   "), 200)

      # `hash("")` is a publicly known constant. A slug claimed with a blank key
      # would be claimable by anyone able to send an empty header, which is
      # worse than being unclaimed because it looks protected.
      refute TournamentKeys.claimed?(slug)
    end

    test "one key does not unlock a different tournament" do
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.keizer()

      publish(first, key: @key)
      publish(second, key: @other_key)

      conn = publish(SnapshotPayloads.republished(second), key: @key)

      assert %{"error" => "key_mismatch"} = json_response(conn, 403)
    end
  end

  describe "tournaments published before keys existed" do
    test "a legacy slug with no key still publishes, and keeps publishing", %{payload: payload} do
      slug = slug_of(payload)

      # Production-shaped: rows that arrived before this feature, so there is a
      # slug with snapshots and no key. Ingested through the context with no
      # key at all, exactly as the old code path did.
      {:ok, _} = Snapshots.ingest(payload, received_at: ~U[2026-03-02 14:00:00.000000Z])
      refute TournamentKeys.claimed?(slug)

      assert %{"status" => "ok"} =
               json_response(publish(SnapshotPayloads.republished(payload)), 200)

      refute TournamentKeys.claimed?(slug)
      assert length(Snapshots.history(slug)) == 2
    end

    test "a legacy slug is adopted by the first publish that carries a key", %{payload: payload} do
      slug = slug_of(payload)
      {:ok, _} = Snapshots.ingest(payload, received_at: ~U[2026-03-02 14:00:00.000000Z])

      # The whole migration story: the arbiter updates their client, it starts
      # sending a key, and the slug is claimed in passing. No backfill, no
      # admin step, no downtime.
      assert %{"status" => "ok"} =
               json_response(publish(SnapshotPayloads.republished(payload), key: @key), 200)

      assert TournamentKeys.claimed?(slug)

      # And from that moment the old behaviour is gone: keyless is refused.
      assert %{"error" => "key_required"} = json_response(publish(payload), 403)
    end

    test "an unclaimed slug can still be taken down, which is the point", %{payload: payload} do
      slug = slug_of(payload)
      {:ok, _} = Snapshots.ingest(payload)

      # A tournament published before keys existed holds the same player names
      # and the same emails as any other. If it could never be removed, the
      # hole this feature exists to close would still be open for exactly the
      # tournaments that have been public longest.
      assert %{"status" => "deleted"} = json_response(takedown(slug), 200)
      assert Snapshots.history(slug) == []
    end
  end

  describe "DELETE /api/tournaments/:slug" do
    test "removes the current snapshot, ALL history and the registrations", %{payload: payload} do
      slug = slug_of(payload)

      publish(payload, key: @key)
      publish(SnapshotPayloads.republished(payload), key: @key)
      register(slug)
      register(slug)

      assert length(Snapshots.history(slug)) == 2
      assert length(Registrations.list_for_tournament(slug)) == 2

      conn = takedown(slug, key: @key)

      assert %{
               "status" => "deleted",
               "slug" => ^slug,
               "deleted" => %{"snapshots" => 2, "registrations" => 2, "key" => 1}
             } = json_response(conn, 200)

      assert Snapshots.history(slug) == []
      assert Snapshots.latest(slug) == nil
      assert Registrations.list_for_tournament(slug) == []
      refute TournamentKeys.claimed?(slug)
    end

    test "after a delete, /history cannot reach an earlier snapshot", %{payload: payload} do
      slug = slug_of(payload)

      publish(payload, key: @key)
      publish(SnapshotPayloads.republished(payload), key: @key)

      # Reachable before, so the assertion after the delete means something.
      assert json_response(
               authed_get(~p"/api/tournaments/#{slug}/history?at=2030-01-01T00:00:00Z"),
               200
             )

      takedown(slug, key: @key)

      # The trap this route exists to avoid: deleting only the CURRENT snapshot
      # empties every public page while leaving the whole event - names,
      # ratings, federations, and any round since retracted - one `?at=` away.
      for at <- ["2030-01-01T00:00:00Z", "2026-03-02T14:00:00Z", "1970-01-01T00:00:00Z"] do
        assert %{"error" => "not_found"} =
                 json_response(authed_get(~p"/api/tournaments/#{slug}/history?at=#{at}"), 404)
      end
    end

    test "after a delete, the public pages return nothing", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)

      assert html_response(get(build_conn(), ~p"/t/#{slug}"), 200)

      takedown(slug, key: @key)

      assert json_response(get(build_conn(), ~p"/api/tournaments/#{slug}"), 404)
      assert html_response(get(build_conn(), ~p"/t/#{slug}"), 404)
      assert html_response(get(build_conn(), ~p"/t/#{slug}/round/1"), 404)
      assert html_response(get(build_conn(), ~p"/t/#{slug}/player/1"), 404)
      assert html_response(get(build_conn(), ~p"/t/#{slug}/register"), 404)

      # And it is off the index, not merely unlinked.
      refute get(build_conn(), ~p"/") |> html_response(200) |> String.contains?(slug)
    end

    test "a delete with the WRONG key refuses and deletes nothing", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)
      register(slug)

      conn = takedown(slug, key: @other_key)

      assert %{"error" => "key_mismatch"} = json_response(conn, 403)
      assert Snapshots.latest(slug).payload == payload
      assert length(Registrations.list_for_tournament(slug)) == 1
      assert TournamentKeys.claimed?(slug)
    end

    test "a delete with NO key against a claimed slug refuses and deletes nothing", %{
      payload: payload
    } do
      slug = slug_of(payload)
      publish(payload, key: @key)
      register(slug)

      assert %{"error" => "key_required"} = json_response(takedown(slug), 403)
      assert Snapshots.latest(slug).payload == payload
      assert length(Registrations.list_for_tournament(slug)) == 1
    end

    test "a delete with no ingest token at all is a 401, before any key is considered", %{
      payload: payload
    } do
      slug = slug_of(payload)
      publish(payload, key: @key)

      conn = delete(build_conn(), ~p"/api/tournaments/#{slug}")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert Snapshots.latest(slug).payload == payload
    end

    test "deleting a slug that holds nothing succeeds and reports three zeroes" do
      # Idempotent: a client retrying after a timeout must not have to tell
      # "already gone" from "you typed it wrong". The counts say which.
      conn = takedown("no-such-open-2026")

      assert %{"deleted" => %{"snapshots" => 0, "registrations" => 0, "key" => 0}} =
               json_response(conn, 200)
    end

    test "a delete takes down one tournament and leaves its neighbour alone" do
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.keizer()

      publish(first, key: @key)
      publish(second, key: @other_key)
      register(slug_of(second))

      takedown(slug_of(first), key: @key)

      assert Snapshots.latest(slug_of(first)) == nil
      assert Snapshots.latest(slug_of(second)).payload == second
      assert length(Registrations.list_for_tournament(slug_of(second))) == 1
      assert TournamentKeys.claimed?(slug_of(second))
    end

    test "a taken-down slug can be claimed again, with a new key", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)
      takedown(slug, key: @key)

      # The dead-laptop recovery that does not need break-glass: take it down,
      # publish it again with a fresh key. Keeping the old claim would have made
      # the tournament permanently unpublishable under its own name.
      assert %{"status" => "ok"} = json_response(publish(payload, key: @other_key), 200)
      assert TournamentKeys.claimed?(slug)
      assert %{"error" => "key_mismatch"} = json_response(publish(payload, key: @key), 403)
    end
  end

  describe "break-glass" do
    test "the server-wide ingest token overrides a lost key, and says so loudly", %{
      payload: payload
    } do
      slug = slug_of(payload)
      publish(payload, key: @key)

      log =
        capture_log(fn ->
          conn = publish(SnapshotPayloads.republished(payload), key: @token)
          assert %{"status" => "ok"} = json_response(conn, 200)
        end)

      assert log =~ "BREAK-GLASS"
      assert log =~ slug
      # The secret is never written down, which is the point of hashing it.
      refute log =~ @key
      assert Snapshots.latest(slug).payload == SnapshotPayloads.republished(payload)
    end

    test "break-glass can take down a tournament whose key is lost", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)
      register(slug)

      log =
        capture_log(fn ->
          conn = takedown(slug, key: @token)

          assert %{"deleted" => %{"snapshots" => 1, "registrations" => 1, "key" => 1}} =
                   json_response(conn, 200)
        end)

      assert log =~ "BREAK-GLASS"
      assert log =~ "delete"
      assert Snapshots.history(slug) == []
      assert Registrations.list_for_tournament(slug) == []
    end

    test "break-glass NEVER claims a slug for the server-wide token", %{payload: payload} do
      slug = slug_of(payload)

      capture_log(fn ->
        assert %{"status" => "ok"} = json_response(publish(payload, key: @token), 200)
      end)

      # Storing a hash of the master secret as a tournament key would promote it
      # into a per-event one, and rotating the ingest token would then lock out
      # every tournament claimed that way.
      refute TournamentKeys.claimed?(slug)
    end

    test "an ordinary publish with the right key logs no break-glass", %{payload: payload} do
      publish(payload, key: @key)

      log =
        capture_log(fn ->
          publish(SnapshotPayloads.republished(payload), key: @key)
        end)

      refute log =~ "BREAK-GLASS"
    end

    test "with no ingest token configured there is no override to reach", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)

      configured = Application.get_env(:openresults, :ingest_token)
      Application.put_env(:openresults, :ingest_token, nil)
      on_exit(fn -> Application.put_env(:openresults, :ingest_token, configured) end)

      # The plug already fails closed here, so this never reaches the key check
      # - asserted so that an unconfigured server cannot be argued into
      # accepting `nil` as a matching override.
      conn = publish(SnapshotPayloads.republished(payload), key: @token)

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert Snapshots.latest(slug).payload == payload
    end
  end

  describe "the registration queue is gated by the key too" do
    # The only route in the system that returns an email address. Before this
    # gate, any holder of the server-wide ingest token could pull the entries
    # for a tournament it had never published - exactly the authority a
    # per-tournament key exists to divide.
    defp pull(slug, opts \\ []) do
      build_conn()
      |> put_req_header("authorization", "Bearer #{Keyword.get(opts, :token, @token)}")
      |> with_key(Keyword.get(opts, :key))
      |> get(~p"/api/tournaments/#{slug}/registrations")
    end

    test "the claiming key reads it", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)
      register(slug)

      body = slug |> pull(key: @key) |> json_response(200)
      assert length(body["registrations"]) == 1
    end

    test "no key against a claimed tournament is refused", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)
      register(slug)

      body = slug |> pull() |> json_response(403)
      assert body["error"] == "key_required"
    end

    test "the wrong key is refused, and reads nothing", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)
      register(slug)

      body = slug |> pull(key: "0000000000000000000000000000dead") |> json_response(403)
      assert body["error"] == "key_mismatch"
      refute body["registrations"]
    end

    test "a legacy tournament published before keys existed is still readable", %{
      payload: payload
    } do
      slug = slug_of(payload)
      publish(payload)
      register(slug)

      # Refusing here would strand the queue rather than protect it: the
      # arbiter running that event has no key to present, and never did.
      body = slug |> pull() |> json_response(200)
      assert length(body["registrations"]) == 1
    end

    test "reading never claims an unclaimed slug", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload)

      slug |> pull() |> json_response(200)

      # A pull silently taking ownership of a tournament this machine never
      # published is the opposite of what a read should do.
      refute OpenResults.TournamentKeys.claimed?(slug)
    end

    test "break-glass reads a claimed tournament", %{payload: payload} do
      slug = slug_of(payload)
      publish(payload, key: @key)
      register(slug)

      body = slug |> pull(key: @token) |> json_response(200)
      assert length(body["registrations"]) == 1
    end
  end
end
