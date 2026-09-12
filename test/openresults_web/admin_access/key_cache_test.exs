defmodule OpenResultsWeb.AdminAccess.KeyCacheTest do
  @moduledoc """
  Cloudflare's signing keys: fetched when needed, never more often than
  that, and kept when Cloudflare cannot be reached.

  The fetcher is a function the test controls, so every fetch the cache
  makes is a message this process receives and can count.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResultsWeb.AdminAccess.KeyCache

  setup do
    reset_admin_access()
    {_private, public} = key_pair()
    {_private, other} = key_pair(:rotated)
    {:ok, public: public, other: other}
  end

  defp serving(documents) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> documents end)

    serve_jwks(fn domain ->
      send(test, {:jwks_fetched, domain})

      Agent.get_and_update(agent, fn
        [only] -> {only, [only]}
        [next | rest] -> {next, rest}
      end)
    end)
  end

  describe "fetching" do
    test "the first request fetches, the next ones read", %{public: public} do
      serving([{:ok, jwks([jwk(public, "kid-1")])}])

      assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
      assert_received {:jwks_fetched, "openresults-test.cloudflareaccess.com"}

      assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
      assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
      refute_received {:jwks_fetched, _}
    end

    test "an unknown kid refetches once, then is refused", %{public: public} do
      Application.put_env(:openresults, :admin_access_refetch_interval_ms, 0)
      serving([{:ok, jwks([jwk(public, "kid-1")])}])

      assert {:ok, _} = KeyCache.key(team_domain(), "kid-1")
      assert_received {:jwks_fetched, _}

      assert :error = KeyCache.key(team_domain(), "kid-unknown")
      assert_received {:jwks_fetched, _}
      # Once per request, not a retry loop.
      refute_received {:jwks_fetched, _}

      # The key already held is untouched by the miss.
      assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
    end

    test "a rotated key is picked up by the refetch its unknown kid causes", %{
      public: public,
      other: other
    } do
      Application.put_env(:openresults, :admin_access_refetch_interval_ms, 0)

      serving([
        {:ok, jwks([jwk(public, "kid-1")])},
        {:ok, jwks([jwk(other, "kid-2"), jwk(public, "kid-1")])}
      ])

      assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
      assert {:ok, ^other} = KeyCache.key(team_domain(), "kid-2")
    end

    test "keys fetched for one team domain are no keys for another", %{public: public} do
      Application.put_env(:openresults, :admin_access_refetch_interval_ms, 0)
      serving([{:ok, jwks([jwk(public, "kid-1")])}])

      assert {:ok, _} = KeyCache.key(team_domain(), "kid-1")
      assert {:ok, _} = KeyCache.key("another-team.cloudflareaccess.com", "kid-1")

      assert_received {:jwks_fetched, "openresults-test.cloudflareaccess.com"}
      assert_received {:jwks_fetched, "another-team.cloudflareaccess.com"}
    end
  end

  describe "rate limiting" do
    test "a flood of made-up kids costs Cloudflare one request, not one each", %{public: public} do
      serving([{:ok, jwks([jwk(public, "kid-1")])}])

      assert {:ok, _} = KeyCache.key(team_domain(), "kid-1")
      assert_received {:jwks_fetched, _}

      for n <- 1..200, do: assert(:error = KeyCache.key(team_domain(), "garbage-#{n}"))

      # Inside the interval: not a single further fetch.
      refute_received {:jwks_fetched, _}
      # And the real key still works throughout.
      assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
    end

    test "concurrent misses share one fetch", %{public: public} do
      serving([{:ok, jwks([jwk(public, "kid-1")])}])

      1..20
      |> Task.async_stream(fn _ -> KeyCache.key(team_domain(), "kid-1") end, max_concurrency: 20)
      |> Enum.each(fn {:ok, result} -> assert {:ok, ^public} = result end)

      assert_received {:jwks_fetched, _}
      refute_received {:jwks_fetched, _}
    end

    test "a cold cache whose first fetch failed does not retry inside the interval" do
      serving([{:error, :econnrefused}])

      capture_log(fn ->
        assert :error = KeyCache.key(team_domain(), "kid-1")
        assert :error = KeyCache.key(team_domain(), "kid-1")
      end)

      assert_received {:jwks_fetched, _}
      refute_received {:jwks_fetched, _}
    end
  end

  describe "failures" do
    test "the keys already held survive a failed refetch", %{public: public} do
      Application.put_env(:openresults, :admin_access_refetch_interval_ms, 0)
      # Every key set counts as stale at once, so each request tries again.
      Application.put_env(:openresults, :admin_access_keys_max_age_ms, 0)

      serving([
        {:ok, jwks([jwk(public, "kid-1")])},
        {:error, :timeout},
        {:ok, %{"keys" => []}},
        {:error, %RuntimeError{message: "boom"}}
      ])

      assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")

      log =
        capture_log(fn ->
          # Unreachable, empty, and a fetcher that itself blew up: each time
          # the held key still answers.
          assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
          assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
          assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
        end)

      assert log =~ "could not fetch Cloudflare Access certs"
      assert log =~ "keeping the 1 key(s) already held"
    end

    test "a fetcher that raises is a failed fetch, not a crashed cache" do
      serve_jwks(fn _domain -> raise "the network is on fire" end)

      capture_log(fn -> assert :error = KeyCache.key(team_domain(), "kid-1") end)

      assert Process.whereis(KeyCache)
    end

    test "a stale key set is replaced, so a withdrawn key stops working", %{
      public: public,
      other: other
    } do
      Application.put_env(:openresults, :admin_access_refetch_interval_ms, 0)
      Application.put_env(:openresults, :admin_access_keys_max_age_ms, 0)

      serving([
        {:ok, jwks([jwk(public, "kid-1")])},
        {:ok, jwks([jwk(other, "kid-2")])}
      ])

      assert {:ok, ^public} = KeyCache.key(team_domain(), "kid-1")
      assert :error = KeyCache.key(team_domain(), "kid-1")
    end
  end

  describe "reading a JWKS document" do
    test "keeps RS256 signing keys and skips everything else", %{public: public} do
      {:RSAPublicKey, n, _e} = public

      short_n =
        Base.url_encode64(:binary.encode_unsigned(div(n, Integer.pow(2, 1100))), padding: false)

      good = jwk(public, "good")

      keys =
        KeyCache.keys_from_jwks(
          jwks([
            good,
            Map.delete(jwk(public, "no-alg-or-use"), "alg") |> Map.delete("use"),
            %{good | "kid" => "ec", "kty" => "EC"},
            %{good | "kid" => "hs", "alg" => "HS256"},
            %{good | "kid" => "enc", "use" => "enc"},
            %{good | "kid" => "short", "n" => short_n},
            %{good | "kid" => "garbled", "n" => "!!!"},
            %{good | "kid" => ""},
            Map.delete(good, "kid"),
            "not a map"
          ])
        )

      assert Map.keys(keys) |> Enum.sort() == ["good", "no-alg-or-use"]
      assert keys["good"] == public
    end

    test "a document without a key list has no keys" do
      assert KeyCache.keys_from_jwks(%{}) == %{}
      assert KeyCache.keys_from_jwks(nil) == %{}
      assert KeyCache.keys_from_jwks(%{"keys" => "nope"}) == %{}
    end
  end

  describe "the default fetcher" do
    setup do
      Application.put_env(:openresults, :admin_access_req_options, plug: {Req.Test, __MODULE__})
      :ok
    end

    test "asks the team domain's certs endpoint", %{public: public} do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test, {:asked, conn.host, conn.request_path, conn.scheme})
        Req.Test.json(conn, jwks([jwk(public, "kid-1")]))
      end)

      assert {:ok, %{"keys" => [_]}} = KeyCache.fetch_jwks(team_domain())

      assert_received {:asked, "openresults-test.cloudflareaccess.com", "/cdn-cgi/access/certs",
                       :https}
    end

    test "a refusal or an unreachable host is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      assert {:error, {:http_status, 503}} = KeyCache.fetch_jwks(team_domain())

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, _} = KeyCache.fetch_jwks(team_domain())
    end
  end
end
