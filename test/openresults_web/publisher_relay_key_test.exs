defmodule OpenResultsWeb.PublisherRelayKeyTest do
  @moduledoc """
  `POST` and `DELETE /api/tournaments/:slug/relay-keys`: the tournament's
  publisher making, replacing and withdrawing the key of its own hall box.
  Who may is exactly who may publish; what comes back works on the live
  endpoint and nowhere else; and a publisher that loses the tournament loses
  the key with it.
  """

  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.RateLimit
  alias OpenResults.RelayKeys
  alias OpenResults.Repo
  alias OpenResults.Snapshots
  alias OpenResultsWeb.RelayKeyController

  @unauthorized %{"error" => "unauthorized", "detail" => "a valid credential is required"}
  @label "openpairings"

  setup do
    RateLimit.reset()
    {installation, key} = installation!()
    slug = mint!(installation)
    tournament_key = random_key()
    slug |> payload() |> publish(key, tournament_key) |> json_response(200)
    {:ok, installation: installation, key: key, slug: slug, tournament_key: tournament_key}
  end

  defp ask(slug, bearer, tournament_key, body \\ %{"label" => @label}) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> bearer(bearer)
    |> tournament_key(tournament_key)
    |> post("/api/tournaments/#{slug}/relay-keys", Jason.encode!(body))
  end

  defp withdraw(slug, bearer, tournament_key, query \\ "?label=#{@label}") do
    build_conn()
    |> bearer(bearer)
    |> tournament_key(tournament_key)
    |> delete("/api/tournaments/#{slug}/relay-keys#{query}")
  end

  defp post_live(slug, bearer) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> bearer(bearer)
    |> post(
      "/api/tournaments/#{slug}/live",
      Jason.encode!(%{"round" => 5, "board" => 1, "moves" => ["e4"]})
    )
  end

  describe "the publisher of the tournament" do
    test "is handed a key, once, that works on the live endpoint", ctx do
      conn = ask(ctx.slug, ctx.key, ctx.tournament_key)
      body = json_response(conn, 201)

      assert %{
               "status" => "ok",
               "relay_key" => "orrk_" <> _ = relay,
               "label" => @label,
               "replaced" => 0,
               "id" => id
             } = body

      assert body["slug"] == ctx.slug
      assert body["hint"] == String.slice(relay, -4, 4)
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert json_response(post_live(ctx.slug, relay), 200)["applied"] == true

      # Listed as the publisher's, with which publisher.
      assert %{origin: "publisher", created_by: by, label: @label} = RelayKeys.get(ctx.slug, id)
      assert by == "installation:#{ctx.installation.id}"

      # Only a fingerprint is kept, and the log never saw the key.
      refute inspect(Repo.all(RelayKeys.RelayKey)) =~ relay
      log = Repo.all(Action) |> inspect()
      assert log =~ "relay_key_create"
      refute log =~ relay
    end

    test "the admin panel lists it as the publisher's and can revoke it", ctx do
      %{"relay_key" => relay, "id" => id} =
        ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)

      html =
        OpenResultsWeb.Admin.RelayKeyHTML.index(%{
          tournament: OpenResults.Tournaments.get(ctx.slug),
          keys: RelayKeys.list(ctx.slug),
          active: 1,
          max_active: RelayKeys.max_active()
        })
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "installation:#{ctx.installation.id}"
      assert html =~ "the publisher, over the API"
      refute html =~ relay

      {:ok, _} = Moderation.revoke_relay_key(ctx.slug, id, admin())
      assert %{"error" => "relay_key_revoked"} = json_response(post_live(ctx.slug, relay), 403)
    end

    test "asking again rotates: one live key, the old one refused", ctx do
      %{"relay_key" => first} = ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)

      assert %{"relay_key" => second, "replaced" => 1} =
               ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)

      refute first == second
      assert RelayKeys.active_count(ctx.slug) == 1
      assert %{"error" => "relay_key_revoked"} = json_response(post_live(ctx.slug, first), 403)
      assert json_response(post_live(ctx.slug, second), 200)["applied"] == true
    end

    test "another label is another key, and an admin's key is never rotated away", ctx do
      {:ok, %{key: by_hand}} = Moderation.create_relay_key(ctx.slug, @label, admin())

      ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)

      ask(ctx.slug, ctx.key, ctx.tournament_key, %{"label" => "second hall"})
      |> json_response(201)

      ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)

      assert RelayKeys.active_count(ctx.slug) == 3
      assert post_live(ctx.slug, by_hand).status == 200
    end

    test "no label is a label too, and is rotated like one", ctx do
      assert %{"label" => "publisher"} =
               ask(ctx.slug, ctx.key, ctx.tournament_key, %{}) |> json_response(201)

      assert %{"replaced" => 1} =
               ask(ctx.slug, ctx.key, ctx.tournament_key, %{"label" => "  "})
               |> json_response(201)

      assert RelayKeys.active_count(ctx.slug) == 1
    end

    test "withdraws its own keys, and only its own", ctx do
      {:ok, %{key: by_hand}} = Moderation.create_relay_key(ctx.slug, @label, admin())
      %{"relay_key" => relay} = ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)

      assert %{"status" => "ok", "revoked" => 1} =
               withdraw(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(200)

      assert %{"error" => "relay_key_revoked"} = json_response(post_live(ctx.slug, relay), 403)
      assert post_live(ctx.slug, by_hand).status == 200

      # Again is not an error.
      assert %{"revoked" => 0} =
               withdraw(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(200)

      assert Repo.all(Action) |> inspect() =~ "relay_key_revoke"
    end

    test "without a label, withdraws every key it made", ctx do
      ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)
      ask(ctx.slug, ctx.key, ctx.tournament_key, %{"label" => "b"}) |> json_response(201)

      assert %{"revoked" => 2} =
               withdraw(ctx.slug, ctx.key, ctx.tournament_key, "") |> json_response(200)
    end

    test "the operator token with the tournament's key may too", ctx do
      slug = unique_slug("op")
      tournament_key = random_key()
      {:ok, _} = Snapshots.ingest(payload(slug), key: tournament_key)

      assert %{"relay_key" => relay} =
               ask(slug, operator_token(), tournament_key) |> json_response(201)

      assert post_live(slug, relay).status == 200
      assert [%{created_by: "operator-token", origin: "publisher"}] = RelayKeys.list(slug)

      assert %{"error" => "key_required"} =
               ask(slug, operator_token(), nil) |> json_response(403)

      assert %{"error" => "key_mismatch"} =
               ask(slug, operator_token(), ctx.tournament_key) |> json_response(403)

      assert RelayKeys.active_count(slug) == 1
    end
  end

  describe "refused" do
    test "no credential, a made-up one, and a relay key itself", ctx do
      %{"relay_key" => relay} = ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)

      for bearer <- [nil, "orik_" <> String.duplicate("a", 43), "nonsense", relay] do
        assert json_response(ask(ctx.slug, bearer, ctx.tournament_key), 401) == @unauthorized
        assert json_response(withdraw(ctx.slug, bearer, ctx.tournament_key), 401) == @unauthorized
      end

      assert RelayKeys.active_count(ctx.slug) == 1
    end

    test "another publisher, even with the tournament's key", ctx do
      {_other, other_key} = installation!({198, 51, 100, 77})

      assert %{"error" => "not_owner"} =
               ask(ctx.slug, other_key, ctx.tournament_key) |> json_response(403)

      assert %{"error" => "not_owner"} =
               withdraw(ctx.slug, other_key, ctx.tournament_key) |> json_response(403)

      assert RelayKeys.list(ctx.slug) == []
    end

    test "the right publisher for the wrong tournament", ctx do
      {other, other_key} = installation!({198, 51, 100, 78})
      theirs = mint!(other)
      their_key = random_key()
      theirs |> payload() |> publish(other_key, their_key) |> json_response(200)

      assert %{"error" => "not_owner"} = ask(theirs, ctx.key, their_key) |> json_response(403)

      assert %{"error" => "not_owner"} =
               ask(theirs, ctx.key, ctx.tournament_key) |> json_response(403)

      assert RelayKeys.list(theirs) == []
    end

    test "the right publisher without, or with the wrong, tournament key", ctx do
      assert %{"error" => "key_required"} = ask(ctx.slug, ctx.key, nil) |> json_response(403)

      assert %{"error" => "key_mismatch"} =
               ask(ctx.slug, ctx.key, random_key()) |> json_response(403)

      # The operator token is not a tournament key in an installation's hands.
      assert %{"error" => "key_mismatch"} =
               ask(ctx.slug, ctx.key, operator_token()) |> json_response(403)

      assert RelayKeys.list(ctx.slug) == []
    end

    test "a suspended publisher may not ask, but may still withdraw", ctx do
      %{"relay_key" => relay} = ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)
      {:ok, _} = Moderation.suspend(ctx.installation.id, admin())

      assert %{"error" => "installation_suspended"} =
               ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(403)

      assert RelayKeys.active_count(ctx.slug) == 1

      assert %{"revoked" => 1} =
               withdraw(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(200)

      assert %{"error" => "relay_key_revoked"} = json_response(post_live(ctx.slug, relay), 403)
    end

    test "a revoked publisher may not ask, and loses the keys it had", ctx do
      %{"relay_key" => relay} = ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)
      {:ok, _} = Moderation.revoke(ctx.installation.id, admin(), [])

      assert %{"error" => "installation_revoked"} =
               ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(403)

      assert %{"error" => "installation_revoked"} =
               withdraw(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(403)

      assert RelayKeys.active_count(ctx.slug) == 0
      assert %{"error" => "relay_key_revoked"} = json_response(post_live(ctx.slug, relay), 403)
    end

    test "a tournament that has not published, and one that does not exist", ctx do
      unpublished = mint!(ctx.installation)

      assert %{"error" => "tournament_not_published"} =
               ask(unpublished, ctx.key, nil) |> json_response(404)

      assert %{"error" => "tournament_not_published"} =
               ask(unique_slug("nothing"), operator_token(), nil) |> json_response(404)
    end

    test "a hidden tournament: no new key, and the old one is no use", ctx do
      %{"relay_key" => relay} = ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)
      {:ok, _} = Moderation.hide(ctx.slug, admin())

      assert %{"error" => "tournament_hidden"} =
               ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(403)

      assert post_live(ctx.slug, relay).status == 404
    end

    test "a paused server", ctx do
      {:ok, _} = Moderation.put_setting(:public_publishing_paused, true, admin())

      assert %{"error" => "publishing_paused"} =
               ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(503)
    end

    test "a tournament that is full of keys", ctx do
      for n <- 1..RelayKeys.max_active(),
          do: {:ok, _} = Moderation.create_relay_key(ctx.slug, "box #{n}", admin())

      assert %{"error" => "relay_key_limit"} =
               ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(409)
    end
  end

  describe "losing the tournament" do
    test "a takedown leaves no key behind", ctx do
      %{"relay_key" => relay} = ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)
      takedown(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(200)

      assert RelayKeys.list(ctx.slug) == []
      assert json_response(post_live(ctx.slug, relay), 401) == @unauthorized
    end

    test "a transfer to another publisher revokes it", ctx do
      %{"relay_key" => relay} = ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)
      {other, _other_key} = installation!({198, 51, 100, 79})
      {:ok, _} = Moderation.transfer(ctx.slug, other.id, admin())

      assert RelayKeys.active_count(ctx.slug) == 0
      assert %{"error" => "relay_key_revoked"} = json_response(post_live(ctx.slug, relay), 403)

      # And the old publisher cannot ask for another.
      assert %{"error" => "not_owner"} =
               ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(403)
    end
  end

  test "has a budget per tournament, and says when to come back", ctx do
    for _ <- 1..RelayKeyController.per_window(),
        do: ask(ctx.slug, ctx.key, ctx.tournament_key) |> json_response(201)

    conn = ask(ctx.slug, ctx.key, ctx.tournament_key)
    assert %{"error" => "rate_limited", "retry_after" => seconds} = json_response(conn, 429)
    assert seconds >= 1
    assert [_] = get_resp_header(conn, "retry-after")

    # Six asks, one live key: the budget is not what keeps them from piling up.
    assert RelayKeys.active_count(ctx.slug) == 1

    # Another tournament is not in that bucket.
    other = mint!(ctx.installation)
    other_key = random_key()
    other |> payload() |> publish(ctx.key, other_key) |> json_response(200)
    assert ask(other, ctx.key, other_key).status == 201
  end
end
