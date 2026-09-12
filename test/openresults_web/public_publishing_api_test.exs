defmodule OpenResultsWeb.PublicPublishingApiTest do
  @moduledoc """
  `GET /api/server`, `POST /api/installations` and `POST /api/tournaments` -
  the three routes public publishing adds - against the contract in
  `docs/public-publishing.md`.
  """

  # Not async: moves application env and spends the node-wide rate limiter.
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Installations
  alias OpenResults.Installations.Installation
  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.Repo
  alias OpenResults.Tournaments

  setup do
    RateLimit.reset()
    :ok
  end

  defp put_env(key, value) do
    previous = Application.get_env(:openresults, key)
    Application.put_env(:openresults, key, value)
    on_exit(fn -> Application.put_env(:openresults, key, previous) end)
  end

  defp register(
         address \\ "198.51.100.7",
         body \\ %{"client" => "OpenPairings", "client_version" => "0.61.0"}
       ) do
    build_conn()
    |> put_req_header("cf-connecting-ip", address)
    |> put_req_header("content-type", "application/json")
    |> post("/api/installations", Jason.encode!(body))
  end

  defp open_registration, do: {:ok, _} = Moderation.put_setting(:registration_open, true, admin())

  describe "GET /api/server" do
    test "reports the operator, the terms and both states, and is never cached" do
      put_env(:operator_name, "ZeroTwo")
      put_env(:terms_url, "https://openresults.example/terms")

      conn = get(build_conn(), "/api/server")

      assert %{
               "name" => "OpenResults",
               "version" => version,
               "operator" => "ZeroTwo",
               "terms_url" => "https://openresults.example/terms",
               "public_registration" => "closed",
               "public_publishing" => "active"
             } = json_response(conn, 200)

      assert version == OpenResults.Build.version()
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "etag") == []
    end

    test "operator and terms are null when unset, and the states follow the switches" do
      put_env(:operator_name, nil)
      put_env(:terms_url, "  ")

      {:ok, _} = Moderation.put_setting(:registration_open, true, admin())
      {:ok, _} = Moderation.put_setting(:public_publishing_paused, true, admin())

      assert %{
               "operator" => nil,
               "terms_url" => nil,
               "public_registration" => "open",
               "public_publishing" => "paused"
             } = json_response(get(build_conn(), "/api/server"), 200)
    end
  end

  describe "POST /api/installations" do
    test "is registration_closed until the switch is flipped, and stores nothing" do
      assert %{"error" => "registration_closed", "detail" => _} = json_response(register(), 503)
      assert Repo.aggregate(Installation, :count) == 0
    end

    test "returns an in_ id and an orik_ key once, and stores only its SHA-256" do
      open_registration()

      conn = register()

      assert %{"installation_id" => id, "key" => key} = json_response(conn, 201)
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert id =~ ~r/\Ain_[A-Za-z0-9_-]{10}\z/
      assert key =~ ~r/\Aorik_[A-Za-z0-9_-]{43}\z/

      assert {:ok, <<_::binary-size(32)>>} =
               key |> String.trim_leading("orik_") |> Base.url_decode64(padding: false)

      row = Repo.get!(Installation, id)
      assert row.key_hash == Installations.hash(key)
      refute row.key_hash =~ String.trim_leading(key, "orik_")
      assert row.status == "active"
      assert row.client == "OpenPairings"
      assert row.client_version == "0.61.0"
      assert row.created_from == "198.51.100.7"

      # The key works, straight away, for what it is for.
      assert %{"slug" => slug} = json_response(mint(key), 201)
      assert slug =~ ~r/\A[A-Za-z0-9_-]{12}\z/
    end

    test "takes the body as advisory: missing, wrong-typed or long fields are stored as best it can" do
      open_registration()

      assert %{"installation_id" => id} =
               json_response(
                 register("198.51.100.8", %{
                   "client" => 7,
                   "client_version" => String.duplicate("9", 500)
                 }),
                 201
               )

      row = Repo.get!(Installation, id)
      assert row.client == nil
      assert String.length(row.client_version) == 50

      assert json_response(
               build_conn()
               |> put_req_header("cf-connecting-ip", "198.51.100.9")
               |> post("/api/installations"),
               201
             )
    end

    test "is address_blocked from a blocked address, before the switch is even considered" do
      {:ok, _} =
        Moderation.block_address(
          "2001:db8::/32",
          DateTime.add(DateTime.utc_now(), 60),
          "spam",
          admin()
        )

      assert json_response(register("2001:db8:1::5"), 403)["error"] == "address_blocked"

      open_registration()
      assert json_response(register("2001:db8:ffff::1"), 403)["error"] == "address_blocked"
      assert json_response(register("2001:db9::1"), 201)
    end

    test "allows 10 per address per day, then rate_limited with Retry-After" do
      open_registration()
      put_env(:registrations_per_address, 3)

      for _ <- 1..3, do: assert(json_response(register("192.0.2.1"), 201))

      conn = register("192.0.2.1")
      assert %{"error" => "rate_limited", "retry_after" => seconds} = json_response(conn, 429)
      assert seconds > 0 and seconds <= 86_400
      assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]

      # A different IPv4 address is a different client.
      assert json_response(register("192.0.2.2"), 201)
    end

    test "counts an IPv6 client by its /64" do
      open_registration()
      put_env(:registrations_per_address, 2)

      assert json_response(register("2001:db8:aa:bb::1"), 201)
      assert json_response(register("2001:db8:aa:bb:ffff:1:2:3"), 201)
      assert json_response(register("2001:db8:aa:bb::99"), 429)["error"] == "rate_limited"

      assert json_response(register("2001:db8:aa:bc::1"), 201)
    end

    test "a v4-mapped IPv6 address shares its IPv4 address's budget" do
      open_registration()
      put_env(:registrations_per_address, 1)

      assert json_response(register("192.0.2.77"), 201)
      assert json_response(register("::ffff:192.0.2.77"), 429)["error"] == "rate_limited"
    end

    test "allows 200 in total per day, across addresses" do
      open_registration()
      put_env(:registrations_per_day, 2)

      assert json_response(register("192.0.2.10"), 201)
      assert json_response(register("192.0.2.11"), 201)
      assert json_response(register("192.0.2.12"), 429)["error"] == "rate_limited"
    end

    test "a refusal for a closed switch does not spend the address's budget" do
      put_env(:registrations_per_address, 1)

      for _ <- 1..5, do: assert(json_response(register("192.0.2.20"), 503))

      open_registration()
      assert json_response(register("192.0.2.20"), 201)
    end
  end

  describe "POST /api/tournaments" do
    test "mints a pending, unpublished slug bound to the installation" do
      {installation, key} = installation!()

      assert %{"slug" => slug} = json_response(mint(key), 201)

      tournament = Tournaments.get(slug)
      assert tournament.status == "pending"
      assert tournament.installation_id == installation.id
      assert tournament.minted_at
      assert Tournaments.status(slug) == :pending
      assert OpenResults.Snapshots.latest(slug) == nil
    end

    test "ignores anything in the body - no name can be requested" do
      {_installation, key} = installation!()

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> bearer(key)
        |> post("/api/tournaments", ~s({"slug":"gent-open-2026"}))

      assert %{"slug" => slug} = json_response(conn, 201)
      refute slug == "gent-open-2026"
      assert Tournaments.get("gent-open-2026") == nil
    end
  end
end
