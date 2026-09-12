defmodule OpenResultsWeb.AdminAccess.JWT do
  @moduledoc """
  Verifies a Cloudflare Access application token, and nothing more general.

  Written against OTP's `:public_key` rather than a JWT library, because this
  app is deliberately light on dependencies and a Cloudflare Access token
  needs exactly one algorithm. A general library's job is to support many;
  this module's job is to refuse all but one.

  ## The order things are checked in

  1. **Shape.** Three base64url parts, a JSON object in the first two, a
     signature in the third. Anything else is `:malformed`.
  2. **Algorithm, before any key is looked at.** `alg` must be exactly
     `"RS256"`. This is the whole defence against the two classic JWT
     attacks: `alg: none` (no signature at all) and HS256 signed with the
     RSA *public* key as the HMAC secret - a verifier that picks its
     algorithm from the token would check that HMAC with the very key it
     fetched and accept it. Here the token never gets to choose, and a
     refused algorithm never even reaches the key cache, so a flood of them
     costs nothing and fetches nothing.
  3. **Key**, by `kid`, through the caller's `:key_for` function.
  4. **Signature**, RSASSA-PKCS1-v1_5 over SHA-256, with
     `:public_key.verify/4`.
  5. **Claims**, only once the signature holds: `iss`, `aud`, then `exp`,
     `nbf` and `iat` with a small leeway.

  The email is deliberately not checked here. A token with a good signature
  and the wrong email is a different answer (a 403, not a 404), and that is
  the plug's decision to make - see `OpenResultsWeb.Plugs.AdminAuth`.
  """

  # Clock skew between Cloudflare's edge and this box, which keeps NTP time.
  # Enough to absorb a real drift; far too little to stretch a token's life
  # in any way that matters.
  @leeway_seconds 60

  # A Cloudflare application token is around a kilobyte. Anything past this
  # is not one, and is refused before a byte of it is decoded.
  @max_token_bytes 8_192

  @type reason ::
          :malformed
          | :unsupported_algorithm
          | :unknown_key
          | :bad_signature
          | :wrong_issuer
          | :wrong_audience
          | :expired
          | :not_yet_valid
          | :issued_in_the_future

  @doc """
  Verifies `token` and returns its claims.

  Options:

    * `:key_for` (required) - `fn kid -> {:ok, rsa_public_key} | :error end`
    * `:issuer` (required) - the exact `iss` to accept
    * `:audience` (required) - a value `aud` must contain
    * `:now` - Unix seconds, for tests; defaults to the system clock
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def verify(token, opts) when is_binary(token) and byte_size(token) <= @max_token_bytes do
    key_for = Keyword.fetch!(opts, :key_for)
    issuer = Keyword.fetch!(opts, :issuer)
    audience = Keyword.fetch!(opts, :audience)
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, header_part, payload_part, header, claims, signature} <- decode(token),
         {:ok, kid} <- algorithm(header),
         {:ok, key} <- key(key_for, kid),
         :ok <- signature(header_part <> "." <> payload_part, signature, key),
         :ok <- issuer(claims, issuer),
         :ok <- audience(claims, audience),
         :ok <- times(claims, now) do
      {:ok, claims}
    end
  end

  def verify(_token, _opts), do: {:error, :malformed}

  defp decode(token) do
    with [header_part, payload_part, signature_part] <- String.split(token, "."),
         {:ok, header} <- json_object(header_part),
         {:ok, claims} <- json_object(payload_part),
         {:ok, signature} when signature != "" <- b64(signature_part) do
      {:ok, header_part, payload_part, header, claims, signature}
    else
      _ -> {:error, :malformed}
    end
  end

  defp json_object(part) do
    with {:ok, json} <- b64(part),
         {:ok, %{} = object} <- Jason.decode(json) do
      {:ok, object}
    else
      _ -> :error
    end
  end

  # Unpadded base64url, as RFC 7515 requires. A padded or standard-alphabet
  # part is not a token Cloudflare issued.
  defp b64(part), do: Base.url_decode64(part, padding: false)

  # `crit` names header extensions the issuer insists a verifier understands.
  # This verifier understands none, so a token that sets it is refused rather
  # than half-understood (RFC 7515, section 4.1.11).
  defp algorithm(%{"alg" => "RS256", "kid" => kid} = header)
       when is_binary(kid) and kid != "" and not is_map_key(header, "crit"),
       do: {:ok, kid}

  defp algorithm(%{"alg" => "RS256"}), do: {:error, :malformed}
  defp algorithm(_header), do: {:error, :unsupported_algorithm}

  defp key(key_for, kid) do
    case key_for.(kid) do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :unknown_key}
    end
  end

  defp signature(signed, signature, key) do
    if :public_key.verify(signed, :sha256, signature, key),
      do: :ok,
      else: {:error, :bad_signature}
  rescue
    # A signature of the wrong length for the key, or a key term that is not
    # an RSA public key, raises inside the crypto library rather than
    # returning false. Either way it is not a valid signature.
    _ -> {:error, :bad_signature}
  end

  defp issuer(%{"iss" => issuer}, issuer), do: :ok
  defp issuer(_claims, _issuer), do: {:error, :wrong_issuer}

  # Cloudflare sends `aud` as a list. A single string is also valid JWT, and
  # accepting it costs nothing.
  defp audience(%{"aud" => audience}, audience) when is_binary(audience), do: :ok

  defp audience(%{"aud" => audiences}, audience) when is_list(audiences) do
    if audience in audiences, do: :ok, else: {:error, :wrong_audience}
  end

  defp audience(_claims, _audience), do: {:error, :wrong_audience}

  # All three are required. Every Access application token carries them, so
  # one without them is not one - and a token with no `exp` would be valid
  # forever.
  defp times(%{"exp" => exp, "nbf" => nbf, "iat" => iat}, now)
       when is_number(exp) and is_number(nbf) and is_number(iat) do
    cond do
      now >= exp + @leeway_seconds -> {:error, :expired}
      now < nbf - @leeway_seconds -> {:error, :not_yet_valid}
      iat > now + @leeway_seconds -> {:error, :issued_in_the_future}
      true -> :ok
    end
  end

  defp times(_claims, _now), do: {:error, :malformed}

  @doc "The leeway applied to `exp`, `nbf` and `iat`, in seconds."
  def leeway_seconds, do: @leeway_seconds
end
