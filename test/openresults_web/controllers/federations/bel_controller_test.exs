defmodule OpenResultsWeb.Federations.BelControllerTest do
  @moduledoc """
  `GET /api/federations/bel/players`: auth (installation key, operator token,
  none, revoked), `not_configured`, ETag/304, and the rate limit.
  """
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Federations.BEL.Store
  alias OpenResults.Moderation
  alias OpenResults.RateLimit

  setup do
    RateLimit.reset()
    Store.reset_for_test()

    path =
      Path.join(
        System.tmp_dir!(),
        "bel_controller_test_#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:openresults, :bel_store_path, path)
    Application.put_env(:openresults, :bel_kbsb_api_url, "http://kbsb.example")
    Application.put_env(:openresults, :bel_kbsb_api_key, "s3cret")

    on_exit(fn ->
      File.rm(path)
      Store.reset_for_test()
      Application.delete_env(:openresults, :bel_kbsb_api_url)
      Application.delete_env(:openresults, :bel_kbsb_api_key)
    end)

    :ok
  end

  test "not_configured (404) when the relay is off" do
    Application.delete_env(:openresults, :bel_kbsb_api_key)
    {installation, key} = installation!()
    _ = installation

    conn = bel_players(key)
    assert %{"error" => "not_configured"} = json_response(conn, 404)
  end

  test "an installation key may read the roster" do
    Store.put([%{national_id: "1", last_name: "Solo"}])
    {_installation, key} = installation!()

    conn = bel_players(key)
    assert %{"count" => 1, "players" => [%{"national_id" => "1"}]} = json_response(conn, 200)
  end

  test "the operator token may read the roster" do
    Store.put([%{national_id: "1"}])
    conn = bel_players(operator_token())
    assert %{"count" => 1} = json_response(conn, 200)
  end

  test "no credential is unauthorized" do
    Store.put([%{national_id: "1"}])
    conn = bel_players(nil)
    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  test "a revoked installation key is refused" do
    Store.put([%{national_id: "1"}])
    {installation, key} = installation!()
    {:ok, _} = Moderation.revoke(installation.id, admin(), hide_tournaments: false)

    conn = bel_players(key)
    assert %{"error" => "installation_revoked"} = json_response(conn, 403)
  end

  test "a suspended installation key is refused" do
    Store.put([%{national_id: "1"}])
    {installation, key} = installation!()
    {:ok, _} = Moderation.suspend(installation.id, admin())

    conn = bel_players(key)
    assert %{"error" => "installation_suspended"} = json_response(conn, 403)
  end

  test "an unrecognised key is the anonymous 401" do
    conn = bel_players("orik_" <> String.duplicate("x", 40))
    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  test "304 when If-None-Match matches the current ETag" do
    Store.put([%{national_id: "1"}])
    {_installation, key} = installation!()

    etag = bel_players(key) |> Plug.Conn.get_resp_header("etag") |> List.first()

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key}")
      |> Plug.Conn.put_req_header("if-none-match", etag)
      |> get("/api/federations/bel/players")

    assert conn.status == 304
    assert conn.resp_body == ""
  end

  test "a changed roster gets a fresh ETag and a 200, not a stale 304" do
    Store.put([%{national_id: "1"}])
    {_installation, key} = installation!()
    etag = bel_players(key) |> Plug.Conn.get_resp_header("etag") |> List.first()

    Store.put([%{national_id: "1"}, %{national_id: "2"}])

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key}")
      |> Plug.Conn.put_req_header("if-none-match", etag)
      |> get("/api/federations/bel/players")

    assert conn.status == 200
    assert json_response(conn, 200)["count"] == 2
  end

  test "gzip is served when the client accepts it" do
    Store.put([%{national_id: "1"}])
    {_installation, key} = installation!()

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key}")
      |> Plug.Conn.put_req_header("accept-encoding", "gzip")
      |> get("/api/federations/bel/players")

    assert Plug.Conn.get_resp_header(conn, "content-encoding") == ["gzip"]
    assert conn.resp_body |> :zlib.gunzip() |> Jason.decode!() |> Map.get("count") == 1
  end

  test "rate limited past the per-minute budget" do
    Store.put([%{national_id: "1"}])
    {_installation, key} = installation!()

    responses = for _ <- 1..21, do: bel_players(key)
    assert Enum.any?(responses, &(&1.status == 429))
  end
end
