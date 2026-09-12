defmodule OpenResultsWeb.PublicPublishingGateTest do
  @moduledoc """
  `OPENRESULTS_PUBLIC_PUBLISHING` unset: a self-hosted copy that upgrades
  must look exactly as it did before.
  """

  # Not async: switches the gate in application env.
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.Snapshots

  @unauthorized %{"error" => "unauthorized", "detail" => "a valid credential is required"}

  setup do
    RateLimit.reset()

    # Created while the feature exists, so there is a real, active key to
    # present once it no longer does - and the switches are open, so nothing
    # but the gate is refusing.
    {installation, key} = installation!()
    slug = mint!(installation)
    {:ok, _} = Moderation.put_setting(:registration_open, true, admin())

    Application.put_env(:openresults, :public_publishing, false)
    on_exit(fn -> Application.put_env(:openresults, :public_publishing, true) end)

    {:ok, key: key, slug: slug}
  end

  defp open_installation_request(path) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, ~s({"client":"OpenPairings","client_version":"0.61.0"}))
  end

  test "POST /api/installations 404s exactly like a route that does not exist" do
    gated = open_installation_request("/api/installations")
    unrouted = open_installation_request("/api/no-such-route")

    assert gated.status == 404
    assert same_answer?(gated, unrouted)
  end

  test "POST /api/tournaments 404s exactly like a route that does not exist, whatever the credential",
       %{key: key} do
    unrouted =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> bearer(key)
      |> post("/api/no-such-route", "{}")

    for bearer <- [key, operator_token(), nil] do
      gated = mint(bearer)
      assert gated.status == 404
      assert same_answer?(gated, unrouted)
    end
  end

  test "an orik_ key is the anonymous 401 on every ingest route, even its own tournament's", %{
    key: key,
    slug: slug
  } do
    for conn <- [
          slug |> payload() |> publish(key, random_key()),
          history(slug, key),
          registrations(slug, key),
          takedown(slug, key)
        ] do
      assert json_response(conn, 401) == @unauthorized
    end

    assert Snapshots.history(slug) == []
  end

  test "the operator token is unaffected" do
    assert json_response(unique_slug() |> payload() |> publish(operator_token()), 200)
  end

  test "GET /api/server says unavailable for both, whatever the switches say" do
    {:ok, _} = Moderation.put_setting(:public_publishing_paused, true, admin())

    assert %{"public_registration" => "unavailable", "public_publishing" => "unavailable"} =
             json_response(get(build_conn(), "/api/server"), 200)
  end

  # Status, body and content type - everything a caller could tell the two
  # apart by, short of the request id.
  defp same_answer?(a, b) do
    a.status == b.status and a.resp_body == b.resp_body and
      get_resp_header(a, "content-type") == get_resp_header(b, "content-type")
  end
end
