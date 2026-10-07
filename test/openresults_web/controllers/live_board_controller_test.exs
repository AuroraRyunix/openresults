defmodule OpenResultsWeb.LiveBoardControllerTest do
  @moduledoc """
  `POST /api/tournaments/:slug/live`: who may call it, what it answers, and
  that a refused update stores nothing. The rules of what is kept are
  `OpenResults.LiveBoardsTest`'s; this is the door.
  """

  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.LiveBoards
  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.Snapshots

  setup do
    RateLimit.reset()
    slug = unique_slug("live-api")
    {:ok, _} = Snapshots.ingest(payload(slug))
    {:ok, slug: slug}
  end

  defp post_live(slug, body, bearer \\ operator_token(), key \\ nil) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> bearer(bearer)
    |> tournament_key(key)
    |> post("/api/tournaments/#{slug}/live", Jason.encode!(body))
  end

  defp board(extra), do: Map.merge(%{"round" => 5, "board" => 1}, extra)

  describe "credentials" do
    test "no token, a wrong token and a malformed header are the same anonymous 401", %{
      slug: slug
    } do
      body = board(%{"moves" => ["e4"]})

      for conn <- [
            post_live(slug, body, nil),
            post_live(slug, body, "not-the-token"),
            build_conn()
            |> put_req_header("content-type", "application/json")
            |> put_req_header("authorization", "Token #{operator_token()}")
            |> post("/api/tournaments/#{slug}/live", Jason.encode!(body))
          ] do
        assert json_response(conn, 401) == %{
                 "error" => "unauthorized",
                 "detail" => "a valid credential is required"
               }
      end

      assert LiveBoards.games(slug) == []
    end

    test "the operator token is accepted, and the game is stored", %{slug: slug} do
      conn = post_live(slug, board(%{"moves" => ~w(e4 e5), "white_ms" => 5000}))

      assert json_response(conn, 200) == %{"status" => "ok", "applied" => true, "ply" => 2}
      assert [%{ply_count: 2, white_ms: 5000}] = LiveBoards.games(slug)
    end

    test "a tournament nothing has published under is a 404", %{slug: _slug} do
      conn = post_live(unique_slug("nothing"), board(%{"moves" => ["e4"]}))
      assert %{"error" => "tournament_not_published"} = json_response(conn, 404)
    end

    test "a hidden tournament cannot be fed", %{slug: slug} do
      {:ok, _} = Moderation.hide(slug, admin())
      conn = post_live(slug, board(%{"moves" => ["e4"]}))
      assert %{"error" => "tournament_not_published"} = json_response(conn, 404)
      assert LiveBoards.games(slug) == []
    end

    test "a claimed tournament needs its own key as well", %{slug: _slug} do
      claimed = unique_slug("claimed")
      key = random_key()
      {:ok, _} = Snapshots.ingest(payload(claimed), key: key)
      body = board(%{"moves" => ["e4"]})

      assert %{"error" => "key_required"} = claimed |> post_live(body) |> json_response(403)

      assert %{"error" => "key_mismatch"} =
               claimed |> post_live(body, operator_token(), "wrong") |> json_response(403)

      assert %{"status" => "ok"} =
               claimed |> post_live(body, operator_token(), key) |> json_response(200)
    end

    test "an installation key works on its own tournament and on no other" do
      {installation, key} = installation!()
      slug = mint!(installation)
      tournament_key = random_key()
      slug |> payload() |> publish(key, tournament_key) |> json_response(200)

      body = board(%{"moves" => ["e4"]})

      assert %{"status" => "ok"} =
               slug |> post_live(body, key, tournament_key) |> json_response(200)

      {_other, other_key} = installation!({198, 51, 100, 21})

      assert %{"error" => "not_owner"} =
               slug |> post_live(body, other_key, tournament_key) |> json_response(403)

      other_slug = unique_slug("not-theirs")
      {:ok, _} = Snapshots.ingest(payload(other_slug))
      assert %{"error" => "not_owner"} = other_slug |> post_live(body, key) |> json_response(403)
    end

    test "a suspended installation is refused, as for a publish" do
      {installation, key} = installation!({198, 51, 100, 22})
      slug = mint!(installation)
      tournament_key = random_key()
      slug |> payload() |> publish(key, tournament_key) |> json_response(200)
      {:ok, _} = Moderation.suspend(installation.id, admin())

      conn = post_live(slug, board(%{"moves" => ["e4"]}), key, tournament_key)
      assert %{"error" => "installation_suspended"} = json_response(conn, 403)
    end
  end

  describe "what it answers" do
    test "an older update is a success that says it was ignored", %{slug: slug} do
      post_live(slug, board(%{"moves" => ~w(e4 e5 Nf3)}))
      conn = post_live(slug, board(%{"moves" => ~w(e4 e5)}))

      assert json_response(conn, 200) == %{
               "status" => "ok",
               "applied" => false,
               "ply" => 3,
               "reason" => "older_than_stored"
             }
    end

    test "an illegal move names its ply and stores nothing", %{slug: slug} do
      conn = post_live(slug, board(%{"moves" => ~w(e4 e5 Ke3)}))

      assert %{"error" => "invalid_moves", "ply" => 3, "detail" => detail} =
               json_response(conn, 422)

      assert detail =~ "Ke3"
      assert LiveBoards.games(slug) == []
    end

    test "malformed bodies are 422s with a code, never a 500", %{slug: slug} do
      for {body, code} <- [
            {%{}, "invalid_request"},
            {board(%{}), "invalid_request"},
            {board(%{"moves" => "e4"}), "invalid_moves"},
            {board(%{"fen" => "junk", "ply" => 1}), "invalid_fen"},
            {board(%{"moves" => ["e4"], "ply" => 5}), "ply_mismatch"},
            {board(%{"moves" => ["e4"], "fen" => "8/8/8/8/8/8/8/k6K w - - 0 1"}), "fen_mismatch"},
            {board(%{"moves" => [], "status" => "dead"}), "invalid_request"},
            {board(%{"round" => "five", "moves" => []}), "invalid_request"}
          ] do
        conn = post_live(slug, body)
        assert %{"error" => ^code} = json_response(conn, 422)
      end

      assert LiveBoards.games(slug) == []
    end

    test "moves that disagree with the stored game are a 409 until replaced", %{slug: slug} do
      post_live(slug, board(%{"moves" => ~w(e4 e5)}))

      assert %{"error" => "moves_conflict"} =
               slug |> post_live(board(%{"moves" => ~w(d4 d5 c4)})) |> json_response(409)

      assert %{"applied" => true, "ply" => 3} =
               slug
               |> post_live(board(%{"moves" => ~w(d4 d5 c4), "replace" => true}))
               |> json_response(200)
    end

    test "a batch answers per board, so one bad board hides nothing", %{slug: slug} do
      conn =
        post_live(slug, %{
          "boards" => [
            board(%{"board" => 1, "moves" => ["e4"]}),
            board(%{"board" => 2, "moves" => ["Ke3"]}),
            board(%{"board" => 3, "moves" => ["d4"]}),
            "junk"
          ]
        })

      assert %{"status" => "ok", "results" => [one, two, three, four]} = json_response(conn, 200)
      assert %{"board" => 1, "status" => "ok", "applied" => true} = one
      assert %{"board" => 2, "status" => "error", "error" => "invalid_moves", "ply" => 1} = two
      assert %{"board" => 3, "status" => "ok"} = three
      assert %{"status" => "error", "error" => "invalid_request"} = four
      assert LiveBoards.games(slug) |> Enum.map(& &1.board) == [1, 3]
    end

    test "a batch is capped", %{slug: slug} do
      boards = for n <- 1..65, do: board(%{"board" => n, "moves" => []})

      assert %{"error" => "invalid_request"} =
               slug |> post_live(%{"boards" => boards}) |> json_response(422)
    end
  end

  test "an installation key has its own budget on this route, not the publish budget" do
    {installation, key} = installation!({198, 51, 100, 23})
    slug = mint!(installation)
    tournament_key = random_key()
    slug |> payload() |> publish(key, tournament_key) |> json_response(200)

    # A publish's budget is a handful a minute; a relay reports far more than
    # that, and every one of these is accepted.
    for n <- 1..30 do
      conn = post_live(slug, board(%{"moves" => [], "white_ms" => n}), key, tournament_key)
      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end
end
