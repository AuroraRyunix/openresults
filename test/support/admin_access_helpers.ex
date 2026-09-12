defmodule OpenResultsWeb.AdminAccessHelpers do
  @moduledoc """
  Cloudflare Access, faked well enough to be checked for real.

  An RSA key pair generated here, a JWKS document built from its public half,
  and tokens signed with its private half - so the admin gate runs its actual
  verification against keys the test controls, and the key fetcher is a
  function that never touches the network.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias OpenResultsWeb.AdminAccess.KeyCache

  @team_domain "openresults-test.cloudflareaccess.com"
  @audience "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
  @admin "arbiter@example.org"

  @env_keys [
    :admin_access_team_domain,
    :admin_access_aud,
    :admin_emails,
    :admin_access_jwks_fetcher,
    :admin_access_req_options,
    :admin_access_refetch_interval_ms,
    :admin_access_keys_max_age_ms,
    :admin_dev_bypass
  ]

  def team_domain, do: @team_domain
  def issuer, do: "https://" <> @team_domain
  def audience, do: @audience
  def admin_email, do: @admin

  @doc """
  An RSA key pair, `{private, public}`, generated once per `name` per test
  run. 2048-bit generation takes long enough that doing it per test would
  show up in the suite's time.
  """
  def key_pair(name \\ :primary) do
    key = {__MODULE__, :key_pair, name}

    case :persistent_term.get(key, nil) do
      nil ->
        private = :public_key.generate_key({:rsa, 2048, 65_537})
        {:RSAPrivateKey, _version, n, e, _d, _p, _q, _dp, _dq, _qi, _other} = private
        pair = {private, {:RSAPublicKey, n, e}}
        :persistent_term.put(key, pair)
        pair

      pair ->
        pair
    end
  end

  @doc "The JWK for a public key, as Cloudflare's certs endpoint lists it."
  def jwk({:RSAPublicKey, n, e}, kid) do
    %{
      "kid" => kid,
      "kty" => "RSA",
      "alg" => "RS256",
      "use" => "sig",
      "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
    }
  end

  def jwks(entries), do: %{"keys" => entries, "public_cert" => %{}, "public_certs" => []}

  @doc "Claims a valid Access application token for the test application carries."
  def claims(overrides \\ %{}) do
    now = System.os_time(:second)

    Map.merge(
      %{
        "aud" => [@audience],
        "email" => @admin,
        "exp" => now + 3600,
        "iat" => now,
        "nbf" => now,
        "iss" => issuer(),
        "type" => "app",
        "identity_nonce" => "nonce",
        "sub" => "3f2a1c9e-0000-4000-8000-000000000000",
        "country" => "BE"
      },
      overrides
    )
  end

  @doc "A compact JWT, RS256-signed with `private` unless the header says otherwise."
  def sign(claims, opts \\ []) do
    {private, _public} = Keyword.get_lazy(opts, :key_pair, fn -> key_pair() end)

    header =
      Map.merge(
        %{"alg" => "RS256", "typ" => "JWT", "kid" => "kid-1"},
        Keyword.get(opts, :header, %{})
      )

    signing_input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    signature = :public_key.sign(signing_input, :sha256, private)

    signing_input <> "." <> b64(signature)
  end

  def b64(binary), do: Base.url_encode64(binary, padding: false)

  @doc "A valid token for `email` (the listed admin by default)."
  def token(email \\ @admin), do: sign(claims(%{"email" => email}))

  @doc """
  Configures the gate as production would be, with a fetcher that serves
  `jwks` (the primary key as `kid-1` by default) and reports every call to
  the calling test as `{:jwks_fetched, team_domain}`.
  """
  def configure_access(opts \\ []) do
    test = self()
    {_private, public} = key_pair()
    document = Keyword.get(opts, :jwks, jwks([jwk(public, "kid-1")]))

    Application.put_env(
      :openresults,
      :admin_access_team_domain,
      Keyword.get(opts, :team_domain, @team_domain)
    )

    Application.put_env(:openresults, :admin_access_aud, @audience)
    Application.put_env(:openresults, :admin_emails, Keyword.get(opts, :emails, @admin))

    serve_jwks(fn domain ->
      send(test, {:jwks_fetched, domain})
      {:ok, document}
    end)

    :ok
  end

  @doc "Replaces the key fetcher."
  def serve_jwks(fetcher),
    do: Application.put_env(:openresults, :admin_access_jwks_fetcher, fetcher)

  @doc "Empties the key cache and restores every admin setting a test may have changed."
  def reset_admin_access do
    saved = for key <- @env_keys, do: {key, Application.fetch_env(:openresults, key)}
    KeyCache.reset()

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:openresults, key, v)
          :error -> Application.delete_env(:openresults, key)
        end
      end

      KeyCache.reset()
    end)

    :ok
  end

  @doc "Puts a valid Access token for `email` on `conn`."
  def with_access_token(conn, email \\ @admin) do
    Plug.Conn.put_req_header(conn, "cf-access-jwt-assertion", token(email))
  end
end
