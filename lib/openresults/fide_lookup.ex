defmodule OpenResults.FideLookup do
  @moduledoc """
  Searching the arbiter's FIDE list on behalf of somebody filling in the entry
  form.

  ## Why this site does not hold the list

  Because the arbiter's app does, and one copy is better than two. A list here
  would be a second large dataset to store, sync and keep fresh, and it would
  be staler than the one the arbiter actually pairs from - so a player could
  pick a rating here that the arbiter's own screen disagrees with, which is
  worse than no search at all.

  ## Proxied, never called from the browser

  The page could fetch the arbiter's machine directly. It does not, for three
  reasons, in order of how much they matter:

    1. it would publish the arbiter's address to every visitor;
    2. it would need CORS on the arbiter's side, which is a permission granted
       to origins rather than to this server;
    3. the token would have to be in the page, which is to say public.

  So the browser asks this site, and this site asks the arbiter.

  ## Optional, and off unless deployed together

  `:endpoint` and `:token` come from configuration. Unset - which is every
  installation where the results site cannot reach an arbiter's machine, and
  the default - `configured?/0` is false, the form does not offer a search,
  and a player types their details as they did before. Nothing degrades; a
  convenience is simply absent.

  On the hosted deployment both applications share a box, so the endpoint is
  `http://localhost:4001` and the request never leaves the machine.
  """

  require Logger

  @timeout 4_000

  @doc "Whether this deployment can reach an arbiter's FIDE list."
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(endpoint()) and not is_nil(token())

  @doc """
  Candidates for `query`, as the entry form's own field names.

  `tempo` is the tournament's `standard` - "rapid", "blitz" or anything else
  for standard - so the rating that comes back is the one this event is
  actually played at. A player entered at their standard rating in a blitz
  tournament is seeded wrong.

  Returns `[]` for everything that is not a clean answer: not configured, a
  query too short to mean anything, a refused token, a machine that is asleep.
  A search that quietly finds nothing is the right failure here - the form
  works without it, and an error message about somebody else's server is not
  something the person typing their name can act on.
  """
  @spec search(String.t(), String.t() | nil) :: [map()]
  def search(query, tempo \\ nil)

  def search(query, tempo) when is_binary(query) do
    query = String.trim(query)

    if configured?() and String.length(query) >= 2 do
      request(query, tempo)
    else
      []
    end
  end

  def search(_query, _tempo), do: []

  defp request(query, tempo) do
    params = [q: query] ++ if(tempo, do: [tempo: tempo], else: [])

    [
      url: endpoint() <> "/internal/fide/search",
      params: params,
      headers: [{"authorization", "Bearer " <> token()}],
      receive_timeout: @timeout,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:openresults, :fide_lookup_req_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"players" => players}}} when is_list(players) ->
        Enum.filter(players, &is_map/1)

      {:ok, %Req.Response{status: status}} ->
        # Logged, not surfaced. The person typing their name cannot act on
        # "the arbiter's machine said 401", and the form still works.
        Logger.warning("FIDE lookup refused by the arbiter's machine: HTTP #{status}")
        []

      {:error, reason} ->
        Logger.warning("FIDE lookup unreachable: #{inspect(reason)}")
        []
    end
  end

  defp endpoint do
    case Application.get_env(:openresults, :fide_lookup_endpoint) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _unset -> nil
    end
  end

  defp token do
    case Application.get_env(:openresults, :fide_lookup_token) do
      token when is_binary(token) and token != "" -> token
      _unset -> nil
    end
  end
end
