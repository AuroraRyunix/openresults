defmodule OpenResultsWeb.InstallationAccessTest do
  @moduledoc """
  What an installation key may and may not do on the four existing ingest
  routes and on minting - the security half of public publishing.

  Through HTTP, because the credential, the route's opt-in and the ownership
  check are three different modules and the property is only true of all
  three together.
  """

  # Not async: several tests move application env (limits, the operator
  # token), and the rate limiter's table is node-wide.
  use OpenResultsWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.Registrations
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments

  @unauthorized %{"error" => "unauthorized", "detail" => "a valid credential is required"}

  setup do
    RateLimit.reset()
    {installation, key} = installation!()
    slug = mint!(installation)
    tkey = random_key()

    {:ok, installation: installation, key: key, slug: slug, tkey: tkey}
  end

  defp register_entry(slug) do
    {:ok, registration} =
      SnapshotPayloads.registration()
      |> Map.put("tournament_slug", slug)
      |> Registrations.ingest()

    registration
  end

  defp error(conn, status), do: json_response(conn, status)["error"]

  defp put_env(key, value) do
    previous = Application.get_env(:openresults, key)
    Application.put_env(:openresults, key, value)
    on_exit(fn -> Application.put_env(:openresults, key, previous) end)
  end

  describe "the owner, on its own minted slug" do
    test "publishes, claiming the slug with its tournament key, and the tournament is pending",
         %{key: key, slug: slug, tkey: tkey} do
      assert %{"status" => "ok", "slug" => ^slug} =
               slug |> payload() |> publish(key, tkey) |> json_response(200)

      assert TournamentKeys.claimed?(slug)
      assert Tournaments.status(slug) == :pending

      # And the tournament key applies on top, exactly as for the operator.
      assert "key_mismatch" ==
               slug
               |> payload()
               |> SnapshotPayloads.republished()
               |> publish(key, random_key())
               |> error(403)

      assert "key_required" ==
               slug |> payload() |> SnapshotPayloads.republished() |> publish(key) |> error(403)
    end

    test "reads its history and its registrations, and deletes", %{
      key: key,
      slug: slug,
      tkey: tkey
    } do
      slug |> payload() |> publish(key, tkey) |> json_response(200)
      register_entry(slug)

      assert json_response(history(slug, key), 200)["tournament"]["slug"] == slug
      assert [_one] = json_response(registrations(slug, key, tkey), 200)["registrations"]

      assert %{"status" => "deleted", "deleted" => %{"snapshots" => 1, "registrations" => 1}} =
               json_response(takedown(slug, key, tkey), 200)

      # The slug is gone rather than sealed: the row went, so the installation
      # no longer owns it either.
      assert Tournaments.get(slug) == nil
      assert error(slug |> payload() |> publish(key, tkey), 403) == "not_owner"
    end
  end

  describe "an installation key cannot touch a tournament that is not its own" do
    setup %{installation: installation} do
      # Operator-published, claimed with a key.
      operator_slug = unique_slug("operator")
      operator_slug |> payload() |> publish(operator_token(), random_key()) |> json_response(200)

      # Legacy: published before keys existed, so no key and no owner.
      legacy_slug = unique_slug("legacy")
      {:ok, _} = Snapshots.ingest(payload(legacy_slug))
      refute TournamentKeys.claimed?(legacy_slug)

      # Another installation's, published and with entries waiting.
      {other, other_key} = installation!({198, 51, 100, 99})
      other_slug = mint!(other)
      other_tkey = random_key()
      other_slug |> payload() |> publish(other_key, other_tkey) |> json_response(200)

      # Never minted by anybody.
      never_slug = unique_slug("never")

      for slug <- [operator_slug, legacy_slug, other_slug], do: register_entry(slug)

      refute installation.id == other.id

      {:ok,
       foreign: [operator_slug, legacy_slug, other_slug, never_slug],
       other_slug: other_slug,
       other_tkey: other_tkey}
    end

    test "cannot read another installation's registrations - the route with email addresses", %{
      key: key,
      other_slug: other_slug,
      other_tkey: other_tkey
    } do
      # Even holding that tournament's own key: ownership is checked first and
      # separately, so a leaked tournament key does not make one installation
      # able to read another's queue.
      for tkey <- [nil, other_tkey, random_key()] do
        conn = registrations(other_slug, key, tkey)
        body = json_response(conn, 403)

        assert body["error"] == "not_owner"
        refute Map.has_key?(body, "registrations")
        refute conn.resp_body =~ "@example.invalid"
      end
    end

    test "publish, delete, history and registrations are all not_owner, and nothing changes", %{
      key: key,
      foreign: foreign
    } do
      for slug <- foreign do
        before_snapshots = Snapshots.history(slug)
        before_entries = Registrations.list_for_tournament(slug)
        before_claim = TournamentKeys.claimed?(slug)

        assert error(
                 slug
                 |> payload()
                 |> SnapshotPayloads.republished()
                 |> publish(key, random_key()),
                 403
               ) ==
                 "not_owner",
               "publish to #{slug}"

        assert error(takedown(slug, key, random_key()), 403) == "not_owner", "delete #{slug}"
        assert error(takedown(slug, key), 403) == "not_owner", "keyless delete #{slug}"
        assert error(history(slug, key), 403) == "not_owner", "history of #{slug}"
        assert error(registrations(slug, key), 403) == "not_owner", "registrations of #{slug}"

        assert Snapshots.history(slug) == before_snapshots
        assert Registrations.list_for_tournament(slug) == before_entries
        assert TournamentKeys.claimed?(slug) == before_claim
        # And a publish to a slug that never existed must not have created it.
        if before_snapshots == [], do: assert(Tournaments.get(slug) == nil)
      end
    end

    test "the operator token still reaches all of them", %{
      foreign: [operator_slug, legacy_slug, other_slug, _]
    } do
      for slug <- [legacy_slug] do
        assert json_response(history(slug, operator_token()), 200)
        assert json_response(registrations(slug, operator_token()), 200)
      end

      # Claimed ones need the key or break-glass - unchanged behaviour.
      capture_log(fn ->
        for slug <- [operator_slug, other_slug] do
          assert json_response(registrations(slug, operator_token(), operator_token()), 200)
        end
      end)
    end
  end

  describe "break-glass" do
    test "an installation key in X-OpenResults-Key never acts as break-glass", %{key: key} do
      slug = unique_slug("claimed")
      slug |> payload() |> publish(operator_token(), random_key()) |> json_response(200)

      log =
        capture_log(fn ->
          conn =
            slug |> payload() |> SnapshotPayloads.republished() |> publish(operator_token(), key)

          assert error(conn, 403) == "key_mismatch"

          assert error(takedown(slug, operator_token(), key), 403) == "key_mismatch"
        end)

      refute log =~ "BREAK-GLASS"
      assert [_still_there] = Snapshots.history(slug)
    end

    test "the operator token in X-OpenResults-Key does nothing for an installation credential", %{
      key: key,
      slug: slug,
      tkey: tkey
    } do
      slug |> payload() |> publish(key, tkey) |> json_response(200)
      register_entry(slug)

      log =
        capture_log(fn ->
          republished = slug |> payload() |> SnapshotPayloads.republished()
          assert error(publish(republished, key, operator_token()), 403) == "key_mismatch"
          assert error(registrations(slug, key, operator_token()), 403) == "key_mismatch"
          assert error(takedown(slug, key, operator_token()), 403) == "key_mismatch"
        end)

      refute log =~ "BREAK-GLASS"
      assert Moderation.list_actions(actor: "break-glass") == []
    end

    test "and on an unclaimed slug it is refused rather than stored as the tournament's key", %{
      key: key,
      slug: slug
    } do
      assert error(slug |> payload() |> publish(key, operator_token()), 403) == "key_mismatch"
      refute TournamentKeys.claimed?(slug)
    end

    test "the operator token still is break-glass, and the action log records it", %{
      key: key,
      slug: slug,
      tkey: tkey
    } do
      slug |> payload() |> publish(key, tkey) |> json_response(200)

      log =
        capture_log(fn ->
          conn =
            slug
            |> payload()
            |> SnapshotPayloads.republished()
            |> publish(operator_token(), operator_token())

          assert json_response(conn, 200)
        end)

      assert log =~ "BREAK-GLASS"

      assert [%{actor: "break-glass", target_type: "tournament", target: ^slug}] =
               Moderation.list_actions(actor: "break-glass")
    end
  end

  describe "suspended and revoked" do
    setup %{key: key, slug: slug, tkey: tkey} do
      slug |> payload() |> publish(key, tkey) |> json_response(200)
      register_entry(slug)
      :ok
    end

    for {status, code} <- [suspend: "installation_suspended", revoke: "installation_revoked"] do
      test "#{status}: mint, publish, history and registrations are #{code}; delete still works",
           %{installation: installation, key: key, slug: slug, tkey: tkey} do
        {:ok, _} =
          case unquote(status) do
            :suspend -> Moderation.suspend(installation.id, admin())
            :revoke -> Moderation.revoke(installation.id, admin(), hide_tournaments: false)
          end

        republished = slug |> payload() |> SnapshotPayloads.republished()

        assert error(mint(key), 403) == unquote(code)
        assert error(publish(republished, key, tkey), 403) == unquote(code)
        assert error(history(slug, key), 403) == unquote(code)
        assert error(registrations(slug, key, tkey), 403) == unquote(code)

        # A stranger's slug is refused the same way - the status is about the
        # key, and it is judged before the tournament.
        assert error(takedown(unique_slug(), key), 403) == "not_owner"

        # Withdrawing your own tournament is never the harmful action.
        assert %{"status" => "deleted"} = json_response(takedown(slug, key, tkey), 200)
        assert Snapshots.history(slug) == []
      end
    end

    test "a revoked key that was also used to hide its tournaments can still delete them", %{
      installation: installation,
      key: key,
      slug: slug,
      tkey: tkey
    } do
      {:ok, _} = Moderation.revoke(installation.id, admin(), hide_tournaments: true)
      assert Tournaments.status(slug) == :hidden
      assert %{"status" => "deleted"} = json_response(takedown(slug, key, tkey), 200)
    end
  end

  describe "a hidden tournament" do
    test "its owner cannot publish to it, and can delete it", %{key: key, slug: slug, tkey: tkey} do
      slug |> payload() |> publish(key, tkey) |> json_response(200)
      {:ok, _} = Moderation.hide(slug, admin())

      republished = slug |> payload() |> SnapshotPayloads.republished()
      assert error(publish(republished, key, tkey), 403) == "tournament_hidden"
      assert [_only_the_first] = Snapshots.history(slug)

      assert %{"status" => "deleted"} = json_response(takedown(slug, key, tkey), 200)
    end
  end

  describe "the snapshot size cap" do
    test "an installation key is refused past the cap with snapshot_too_large and the limit", %{
      key: key,
      slug: slug,
      tkey: tkey
    } do
      small = slug |> payload() |> Jason.encode!() |> byte_size()
      put_env(:installation_max_snapshot_bytes, small - 1)

      conn = slug |> payload() |> publish(key, tkey)

      assert %{"error" => "snapshot_too_large", "limit_bytes" => limit, "detail" => _} =
               json_response(conn, 413)

      assert limit == small - 1
      assert Snapshots.history(slug) == []
      refute TournamentKeys.claimed?(slug)

      # At the limit exactly is allowed.
      put_env(:installation_max_snapshot_bytes, small)
      assert json_response(slug |> payload() |> publish(key, tkey), 200)
    end

    test "the operator token keeps the parser's limit" do
      put_env(:installation_max_snapshot_bytes, 10)
      slug = unique_slug()
      assert json_response(slug |> payload() |> publish(operator_token()), 200)
    end
  end

  describe "the publish budget" do
    test "30 a minute per installation, then rate_limited with Retry-After", %{
      installation: installation,
      key: key,
      slug: slug,
      tkey: tkey
    } do
      put_env(:installation_publishes_per_minute, 3)
      base = payload(slug)

      for round <- 1..3 do
        body = put_in(base, ["standings", "after_round"], round)
        assert json_response(publish(body, key, tkey), 200)
      end

      conn = publish(base, key, tkey)
      assert %{"error" => "rate_limited", "retry_after" => seconds} = json_response(conn, 429)
      assert seconds in 1..60
      assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]

      # Minting spends the same budget.
      assert error(mint(key), 429) == "rate_limited"

      # A different installation has its own.
      {_other, other_key} = installation!()
      assert json_response(mint(other_key), 201)

      # Deleting is never rate limited.
      assert json_response(takedown(slug, key, tkey), 200)
      refute installation.id == nil
    end
  end

  describe "publishing_paused" do
    test "refuses publish and mint for installation keys only; delete still works", %{
      key: key,
      slug: slug,
      tkey: tkey
    } do
      slug |> payload() |> publish(key, tkey) |> json_response(200)
      {:ok, _} = Moderation.put_setting(:public_publishing_paused, true, admin())

      republished = slug |> payload() |> SnapshotPayloads.republished()
      assert error(publish(republished, key, tkey), 503) == "publishing_paused"
      assert error(mint(key), 503) == "publishing_paused"

      # Reads are not publishing.
      assert json_response(history(slug, key), 200)

      # The operator is unaffected.
      assert json_response(unique_slug() |> payload() |> publish(operator_token()), 200)

      assert json_response(takedown(slug, key, tkey), 200)
    end
  end

  describe "address blocks" do
    test "refuse publish and mint from the address; the operator token is exempt; delete works",
         %{
           key: key,
           slug: slug,
           tkey: tkey
         } do
      slug |> payload() |> publish(key, tkey) |> json_response(200)

      {:ok, _} =
        Moderation.block_address(
          "203.0.113.0/24",
          DateTime.add(DateTime.utc_now(), 3600),
          "flood",
          admin()
        )

      from_blocked = build_conn() |> put_req_header("cf-connecting-ip", "203.0.113.50")
      republished = slug |> payload() |> SnapshotPayloads.republished()

      assert error(publish(republished, key, tkey, from_blocked), 403) == "address_blocked"
      assert error(mint(key, blocked_conn()), 403) == "address_blocked"

      # From elsewhere, the same key works.
      assert json_response(publish(republished, key, tkey), 200)

      # The operator token, from the blocked range.
      assert json_response(
               unique_slug() |> payload() |> publish(operator_token(), nil, blocked_conn()),
               200
             )

      assert json_response(takedown(slug, key, tkey, blocked_conn()), 200)
    end

    defp blocked_conn, do: build_conn() |> put_req_header("cf-connecting-ip", "203.0.113.51")
  end

  describe "minting" do
    test "the operator token is refused with installation_key_required" do
      assert error(mint(operator_token()), 403) == "installation_key_required"
    end

    test "counts pending and listed tournaments against the limit, not hidden ones", %{
      installation: installation,
      key: key,
      slug: first
    } do
      put_env(:installation_max_tournaments, 2)

      assert %{"slug" => second} = json_response(mint(key), 201)
      assert %{"error" => "tournament_limit", "limit" => 2} = json_response(mint(key), 403)

      {:ok, _} = Moderation.approve(second, admin())
      assert error(mint(key), 403) == "tournament_limit"

      {:ok, _} = Moderation.hide(first, admin())
      assert %{"slug" => third} = json_response(mint(key), 201)
      assert Tournaments.get(third).installation_id == installation.id
    end

    test "an unknown key and no key are the anonymous 401" do
      assert json_response(mint("orik_" <> String.duplicate("A", 43)), 401) == @unauthorized
      assert json_response(mint(nil), 401) == @unauthorized
    end
  end

  describe "an unknown installation key" do
    test "is the same 401 as any other wrong token, on every ingest route", %{slug: slug} do
      unknown = "orik_" <> String.duplicate("x", 43)

      for conn <- [
            slug |> payload() |> publish(unknown),
            history(slug, unknown),
            registrations(slug, unknown),
            takedown(slug, unknown),
            slug |> payload() |> publish("not-a-token-at-all")
          ] do
        assert json_response(conn, 401) == @unauthorized
      end
    end
  end
end
