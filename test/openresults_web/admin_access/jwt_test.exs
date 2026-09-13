defmodule OpenResultsWeb.AdminAccess.JWTTest do
  @moduledoc """
  The token check on its own, with no plug, no cache and no network: a key
  generated here, tokens signed here, and a `key_for` that reports whether it
  was even asked.

  The attacks worth a test each are the two the JWT format is famous for -
  `alg: none` and HS256 signed with the RSA public key - plus the ordinary
  ways a real token is wrong for this application.
  """
  use ExUnit.Case, async: true

  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResultsWeb.AdminAccess.JWT

  setup do
    {_private, public} = key_pair()
    test = self()

    key_for = fn kid ->
      send(test, {:key_asked, kid})
      if kid == "kid-1", do: {:ok, public}, else: :error
    end

    {:ok, key_for: key_for, public: public}
  end

  defp verify(token, key_for, opts \\ []) do
    JWT.verify(
      token,
      Keyword.merge([key_for: key_for, issuer: issuer(), audience: audience()], opts)
    )
  end

  describe "a token Cloudflare would issue for this application" do
    test "is accepted, and its claims come back", %{key_for: key_for} do
      assert {:ok, claims} = verify(sign(claims()), key_for)
      assert claims["email"] == admin_email()
    end

    test "with `aud` as a single string rather than a list", %{key_for: key_for} do
      assert {:ok, _} = verify(sign(claims(%{"aud" => audience()})), key_for)
    end

    test "within the leeway either side of its lifetime", %{key_for: key_for} do
      now = System.os_time(:second)
      leeway = JWT.leeway_seconds()

      just_expired = claims(%{"exp" => now - leeway + 5})
      assert {:ok, _} = verify(sign(just_expired), key_for)

      nearly_valid = claims(%{"nbf" => now + leeway - 5, "iat" => now + leeway - 5})
      assert {:ok, _} = verify(sign(nearly_valid), key_for)
    end
  end

  describe "the algorithm is never the token's to choose" do
    test "alg: none is refused before any key is looked up", %{key_for: key_for} do
      header = b64(Jason.encode!(%{"alg" => "none", "typ" => "JWT", "kid" => "kid-1"}))
      payload = b64(Jason.encode!(claims()))

      # Both spellings an unsigned token takes in the wild: an empty third
      # part, and a junk one.
      assert {:error, _} = verify(header <> "." <> payload <> ".", key_for)

      assert {:error, :unsupported_algorithm} =
               verify(header <> "." <> payload <> ".AAAA", key_for)

      refute_received {:key_asked, _}
    end

    test "HS256 signed with the RSA public key as the secret is refused", %{
      key_for: key_for,
      public: public
    } do
      # The key-confusion attack. The public key is public - it is on
      # Cloudflare's certs endpoint for anyone to fetch - so an attacker can
      # HMAC a token with its bytes. A verifier that lets the header pick the
      # algorithm would then check that HMAC with the very key it fetched,
      # and it would match. Every encoding of the key a library might use as
      # an HMAC secret is tried.
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, public)])
      der = :public_key.der_encode(:RSAPublicKey, public)
      {:RSAPublicKey, n, _e} = public

      for secret <- [pem, der, :binary.encode_unsigned(n)] do
        header = b64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT", "kid" => "kid-1"}))
        payload = b64(Jason.encode!(claims()))
        mac = :crypto.mac(:hmac, :sha256, secret, header <> "." <> payload)

        assert {:error, :unsupported_algorithm} =
                 verify(header <> "." <> payload <> "." <> b64(mac), key_for)
      end

      refute_received {:key_asked, _}
    end

    test "and so is every other algorithm, including RS256's cousins", %{key_for: key_for} do
      for alg <- ["RS384", "RS512", "PS256", "ES256", "HS512", "rs256", "RS256 ", nil] do
        token = sign(claims(), header: %{"alg" => alg})
        assert {:error, :unsupported_algorithm} = verify(token, key_for), "alg #{inspect(alg)}"
      end

      refute_received {:key_asked, _}
    end

    test "a header naming critical extensions is refused", %{key_for: key_for} do
      token = sign(claims(), header: %{"crit" => ["exp"]})
      assert {:error, :malformed} = verify(token, key_for)
    end
  end

  describe "the signature" do
    test "a tampered payload no longer verifies", %{key_for: key_for} do
      [header, _payload, signature] = claims() |> sign() |> String.split(".")
      promoted = b64(Jason.encode!(claims(%{"email" => "someone-else@example.org"})))

      assert {:error, :bad_signature} =
               verify(Enum.join([header, promoted, signature], "."), key_for)
    end

    test "a token signed by another key under a known kid does not verify", %{key_for: key_for} do
      token = sign(claims(), key_pair: key_pair(:intruder))
      assert {:error, :bad_signature} = verify(token, key_for)
    end

    test "an unknown kid is an unknown key", %{key_for: key_for} do
      assert {:error, :unknown_key} = verify(sign(claims(), header: %{"kid" => "kid-9"}), key_for)
      assert_received {:key_asked, "kid-9"}
    end

    test "a signature the crypto library cannot even check is refused, not waved through", %{
      key_for: key_for
    } do
      # `:public_key.verify/4` raises rather than answering false for a key term
      # that is not an RSA public key, and can for a signature of the wrong
      # size. The rescue has to answer :bad_signature - one that answered :ok
      # would admit every token whose check blew up.
      [header, payload, _signature] = claims() |> sign() |> String.split(".")

      for junk <- [<<0>>, :crypto.strong_rand_bytes(600)] do
        assert {:error, :bad_signature} =
                 verify(Enum.join([header, payload, b64(junk)], "."), key_for)
      end

      not_a_key = fn _kid -> {:ok, :not_an_rsa_key} end
      assert {:error, :bad_signature} = verify(sign(claims()), not_a_key)
    end

    test "a missing kid is malformed, and no key is asked for", %{key_for: key_for} do
      header = b64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}))
      payload = b64(Jason.encode!(claims()))

      assert {:error, :malformed} = verify(header <> "." <> payload <> ".AAAA", key_for)
      refute_received {:key_asked, _}
    end
  end

  describe "the claims, once the signature holds" do
    test "wrong audience", %{key_for: key_for} do
      assert {:error, :wrong_audience} =
               verify(sign(claims(%{"aud" => ["another-app"]})), key_for)

      assert {:error, :wrong_audience} = verify(sign(claims(%{"aud" => "another-app"})), key_for)
      assert {:error, :wrong_audience} = verify(sign(Map.delete(claims(), "aud")), key_for)
    end

    test "wrong issuer - another team, or the right host without https", %{key_for: key_for} do
      for iss <- [
            "https://someone-else.cloudflareaccess.com",
            "http://" <> team_domain(),
            team_domain(),
            issuer() <> "/"
          ] do
        assert {:error, :wrong_issuer} = verify(sign(claims(%{"iss" => iss})), key_for), iss
      end
    end

    test "expired", %{key_for: key_for} do
      now = System.os_time(:second)
      token = sign(claims(%{"exp" => now - JWT.leeway_seconds() - 1, "iat" => now - 7200}))

      assert {:error, :expired} = verify(token, key_for)
    end

    test "expiry is exact at the edge of the leeway, not a second later", %{key_for: key_for} do
      # `:now` pins the clock, so the boundary is tested rather than raced.
      now = System.os_time(:second)
      edge = now - JWT.leeway_seconds()
      claims = claims(%{"iat" => now - 7200, "nbf" => now - 7200})

      assert {:error, :expired} = verify(sign(%{claims | "exp" => edge}), key_for, now: now)
      assert {:ok, _} = verify(sign(%{claims | "exp" => edge + 1}), key_for, now: now)
    end

    test "not valid before a time still in the future", %{key_for: key_for} do
      later = System.os_time(:second) + JWT.leeway_seconds() + 60
      assert {:error, :not_yet_valid} = verify(sign(claims(%{"nbf" => later})), key_for)
    end

    test "issued in the future", %{key_for: key_for} do
      later = System.os_time(:second) + JWT.leeway_seconds() + 60
      assert {:error, :issued_in_the_future} = verify(sign(claims(%{"iat" => later})), key_for)
    end

    test "missing any of exp, nbf or iat", %{key_for: key_for} do
      for claim <- ["exp", "nbf", "iat"] do
        assert {:error, :malformed} = verify(sign(Map.delete(claims(), claim)), key_for), claim
      end
    end
  end

  describe "shapes that are not a token at all" do
    test "are malformed", %{key_for: key_for} do
      valid = sign(claims())

      for garbage <- [
            "",
            "a.b",
            "a.b.c.d",
            "not a token",
            String.replace(valid, ".", ". ", global: false),
            # Padded base64 is not what RFC 7515 sends.
            valid <> "=",
            # A JSON array where the header object belongs.
            b64("[1]") <> "." <> b64("{}") <> ".AAAA",
            String.duplicate("a", 9_000)
          ] do
        assert {:error, reason} = verify(garbage, key_for)
        assert reason in [:malformed, :bad_signature], inspect(garbage)
      end
    end
  end
end
