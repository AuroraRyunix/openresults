defmodule OpenResultsWeb.InstallationController do
  @moduledoc """
  `POST /api/installations` - an OpenPairings installation asking for its own
  key.

  The one route that hands a credential to anybody who asks, so it is guarded
  by everything that does not need one:

    1. the environment gate - with it off, this route does not exist
       (`OpenResultsWeb.Plugs.PublicPublishingGate`);
    2. address blocks - `address_blocked`;
    3. the `registration_open` switch - `registration_closed`, and it
       defaults to closed;
    4. two budgets - per client address, then for the whole server, each per
       24 hours - `rate_limited` with `Retry-After`.

  Blocks and the switch are checked BEFORE the budgets, so a client refused
  for either does not also spend its address's budget trying: an OpenPairings
  copy that tries while registration is closed must not find itself rate
  limited on the morning it opens.

  The per-address budget counts an IPv6 client by its /64. A host on IPv6 is
  normally handed a whole /64 and can pick any address in it, so keying on the
  full address would give one laptop 2^64 budgets. IPv4 is keyed on the
  address itself.

  The body is taken as advisory: `client` and `client_version` are stored
  when they are strings and ignored when they are not. There is nothing to
  validate them against, and refusing a key over a malformed version string
  would turn a cosmetic field into an outage.

  The response carries `Cache-Control: no-store`. It holds a secret that
  exists nowhere else.
  """

  use OpenResultsWeb, :controller

  import Bitwise

  alias OpenResults.AddressBlocks
  alias OpenResults.Installations
  alias OpenResults.PublicPublishing
  alias OpenResults.RateLimit
  alias OpenResults.Settings
  alias OpenResultsWeb.ApiError
  alias OpenResultsWeb.ClientAddress

  @day_ms :timer.hours(24)

  def create(conn, _params) do
    address = ClientAddress.of(conn)

    with :ok <- not_blocked(address),
         :ok <- open(),
         :ok <- take({:installation_registration, budget_key(address)}, per_address()),
         :ok <- take(:installation_registration_all, per_day()),
         {:ok, %{installation: installation, key: key}} <-
           Installations.register(conn.body_params, address) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(:created)
      |> json(%{installation_id: installation.id, key: key})
    else
      {:error, code, extra} -> ApiError.send(conn, code, extra)
      {:error, code} when is_atom(code) -> ApiError.send(conn, code)
    end
  end

  defp not_blocked(address) do
    if AddressBlocks.blocked?(address), do: {:error, :address_blocked}, else: :ok
  end

  defp open do
    if Settings.get(:registration_open), do: :ok, else: {:error, :registration_closed}
  end

  defp take(key, limit) do
    case RateLimit.take(key, limit: limit, window_ms: @day_ms) do
      :ok ->
        :ok

      {:denied, retry_in_ms} ->
        {:error, :rate_limited, %{retry_after: ApiError.retry_seconds(retry_in_ms)}}
    end
  end

  defp per_address, do: PublicPublishing.registrations_per_address()
  defp per_day, do: PublicPublishing.registrations_per_day()

  # One shape per family, always a tuple, for the reason
  # `OpenResults.RateLimit` gives about keys.
  defp budget_key({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp budget_key({_, _, _, _} = ipv4), do: ipv4
  defp budget_key({a, b, c, d, _, _, _, _}), do: {a, b, c, d, 0, 0, 0, 0}
end
