defmodule OpenResults.Federations.BEL.Api do
  @moduledoc """
  Walks the KBSB data platform's roster export
  (`GET /api/v1/players_national/export`) on this server's behalf, the same
  cursor-paginated walk `PairingsEngine.Federations.BEL.Api` does against
  the same endpoint from the OpenPairings side - see that module for why the
  walk is a full replace every time rather than an incremental `?since=`.

  Every row is reduced through `OpenResults.Federations.BEL.Fields.reduce/1`
  as soon as it is read off the wire, so a field this relay must never
  forward never exists in this process's memory for longer than one page.
  """

  require Logger
  alias OpenResults.Federations.BEL.{Config, Fields}

  @page_size 1000
  @max_pages 500
  @receive_timeout :timer.seconds(30)

  # A transient failure (a dropped connection, a 5xx, a timeout) is retried
  # a few times with a growing pause before the whole sync gives up for this
  # run - the scheduler tries again tomorrow, or sooner at boot. Configurable
  # so tests exercising the failure path do not have to sleep through it.
  defp retries, do: Application.get_env(:openresults, :bel_retries, 3)

  defp backoff_ms,
    do: Application.get_env(:openresults, :bel_retry_backoff_ms, [1_000, 4_000, 10_000])

  @doc """
  Walks the whole roster export and returns `{:ok, rows}`, each row already
  reduced to `Fields.allowed/0`, or `{:error, message}`.
  """
  def fetch_all(on_progress \\ fn _count -> :ok end) do
    if Config.enabled?() do
      walk(nil, [], 0, on_progress)
    else
      {:error, "OPENRESULTS_KBSB_API_URL / OPENRESULTS_KBSB_API_KEY are not configured"}
    end
  end

  defp walk(_cursor, _acc, page, _on_progress) when page >= @max_pages do
    {:error, "KBSB export did not finish after #{@max_pages} pages - aborting"}
  end

  defp walk(cursor, acc, page, on_progress) do
    case get_page_with_retry(cursor, retries()) do
      {:ok, %{rows: rows, next_cursor: next}} ->
        acc = acc ++ rows
        on_progress.(length(acc))

        case advance(cursor, next) do
          :done -> {:ok, acc}
          {:ok, next} -> walk(next, acc, page + 1, on_progress)
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp get_page_with_retry(cursor, attempts_left) do
    case get_page(cursor) do
      {:ok, _} = ok ->
        ok

      {:error, _reason} = error when attempts_left <= 0 ->
        error

      {:error, reason} ->
        backoff = backoff_ms()
        wait = Enum.at(backoff, retries() - attempts_left, List.last(backoff))
        Logger.warning("KBSB export page failed (#{reason}), retrying in #{wait}ms")
        Process.sleep(wait)
        get_page_with_retry(cursor, attempts_left - 1)
    end
  end

  defp advance(_cursor, nil), do: :done
  defp advance(nil, next) when is_integer(next), do: {:ok, next}
  defp advance(cursor, next) when is_integer(next) and next > cursor, do: {:ok, next}

  defp advance(cursor, next) do
    {:error, "KBSB export cursor did not advance (#{inspect(cursor)} -> #{inspect(next)})"}
  end

  defp get_page(cursor) do
    params = [limit: @page_size] ++ if(cursor, do: [cursor: cursor], else: [])

    url =
      Config.api_url()
      |> String.trim_trailing("/")
      |> Kernel.<>("/api/v1/players_national/export")

    opts =
      Keyword.merge(
        [
          params: params,
          headers: [{"x-api-key", Config.api_key()}],
          receive_timeout: @receive_timeout,
          # Req's own retry is disabled: `get_page_with_retry/2` above is
          # this module's retry/backoff, and stacking Req's on top of it
          # would multiply both the wait and the request count.
          retry: false
        ],
        req_options()
      )

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: 200, body: %{"players" => players} = body}} ->
        {:ok, %{rows: Enum.map(players, &Fields.reduce/1), next_cursor: body["next_cursor"]}}

      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.error("KBSB export: unexpected body #{inspect(body, limit: 5)}")
        {:error, "unexpected 200 body"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, "transport error: #{inspect(reason)}"}
    end
  end

  # Extra options merged into every request, so tests can pass a `plug:` and
  # exercise the walk without standing up a server - mirrors
  # `PairingsEngine.Federations.BEL.Api.req_options/0`.
  defp req_options, do: Application.get_env(:openresults, :bel_req_options, [])
end
