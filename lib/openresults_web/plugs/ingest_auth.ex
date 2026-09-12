defmodule OpenResultsWeb.Plugs.IngestAuth do
  @moduledoc """
  Bearer-token gate on the write routes, and the one place that decides which
  credential a request carries.

  ## Two credentials

  | credential | assigned as | may |
  |---|---|---|
  | the operator token (`OPENRESULTS_INGEST_TOKEN`) | `:operator` | everything, as before |
  | an installation key (`orik_...`) | `{:installation, installation}` | only what a route opted into, and only on its own tournaments |

  Reading the operator token from application config rather than a literal is
  what lets production supply it from the environment at boot without it ever
  entering the repository.

  ## Fails closed, and says nothing to strangers

  A missing header, a malformed header, a wrong token, an unconfigured server,
  an installation key this server never issued, and any `orik_` key at all
  while public publishing is switched off at the environment - all produce
  the same 401 with the same body, because a caller that can tell "wrong
  token" from "server has no token" learns something it has no business
  knowing.

  A key that exists but is suspended or revoked gets its own 403 instead
  (`installation_suspended`, `installation_revoked`). That tells nothing to a
  stranger - only the key's holder can receive it - and it tells the arbiter
  holding it which of two very different situations they are in.

  ## Default-deny for installation keys

  The router puts this plug on the pipeline rather than on each action so
  that "a route added here later is authenticated by default rather than by
  remembering". An installation key has to keep that property, and it is the
  more dangerous credential to get wrong: the public holds it.

  So an installation key is REFUSED - with the anonymous 401, exactly as if it
  were unknown - on every route that has not opted in. A route opts in in the
  router, with `private: %{installation_access: action}`, and the action
  names what the route does. The checks that action implies run here, in
  `OpenResultsWeb.InstallationAccess`, before the controller is reached, so a
  route cannot opt in without them - including the ownership check for every
  action that names a tournament. `test/openresults_web/default_deny_test.exs`
  walks the router to prove it.
  """

  import Plug.Conn

  require Logger

  alias OpenResults.Installations
  alias OpenResults.PublicPublishing
  alias OpenResultsWeb.InstallationAccess

  @unauthorized Jason.encode!(%{error: "unauthorized", detail: "a valid credential is required"})

  def init(opts), do: opts

  def call(conn, _opts) do
    case presented_token(conn) do
      {:ok, presented} -> authenticate(conn, presented)
      :error -> unauthorized(conn)
    end
  end

  defp authenticate(conn, presented) do
    cond do
      operator_token?(presented) ->
        assign(conn, :credential, :operator)

      installation = installation(presented) ->
        case conn.private[:installation_access] do
          action when is_atom(action) and not is_nil(action) ->
            InstallationAccess.authorize(conn, installation, action)

          # The route did not opt in. The key is not a credential here.
          _not_opted_in ->
            unauthorized(conn)
        end

      true ->
        if configured_token() == :error do
          Logger.warning(
            "publish rejected: :ingest_token is not configured, so no token can be accepted"
          )
        end

        unauthorized(conn)
    end
  end

  defp operator_token?(presented) do
    case configured_token() do
      {:ok, expected} -> token_matches?(expected, presented)
      :error -> false
    end
  end

  # Only when the feature exists on this server, and only for something
  # shaped like an installation key - a wrong operator token is not worth a
  # database lookup.
  defp installation(presented) do
    with true <- PublicPublishing.enabled?(),
         true <- Installations.key?(presented),
         {:ok, installation} <- Installations.authenticate(presented) do
      installation
    else
      _not_an_installation -> nil
    end
  end

  defp configured_token do
    case Application.get_env(:openresults, :ingest_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _unset -> :error
    end
  end

  defp presented_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         ["bearer", token] <- header |> String.split(" ", parts: 2) |> downcase_scheme(),
         false <- token == "" do
      {:ok, token}
    else
      _unusable -> :error
    end
  end

  defp downcase_scheme([scheme, token]), do: [String.downcase(scheme), token]
  defp downcase_scheme(other), do: other

  defp token_matches?(expected, presented) do
    # `==` on a secret is a timing oracle: it returns at the first differing
    # byte, so an attacker who can measure the response can recover the token
    # one byte at a time. `secure_compare/2` always looks at everything.
    #
    # Hashing first is not about secrecy - both digests are computed here from
    # values already in memory. It equalises the lengths, because
    # `secure_compare/2` returns early when its arguments differ in size and
    # would otherwise leak how long the real token is.
    Plug.Crypto.secure_compare(
      :crypto.hash(:sha256, expected),
      :crypto.hash(:sha256, presented)
    )
  end

  @doc false
  # The one anonymous answer, shared with `InstallationAccess` so that an
  # unknown action cannot be told from an unknown credential.
  def unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, @unauthorized)
    |> halt()
  end
end
