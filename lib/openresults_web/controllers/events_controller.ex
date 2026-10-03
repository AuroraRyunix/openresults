defmodule OpenResultsWeb.EventsController do
  @moduledoc """
  `GET /t/:slug/events` - a Server-Sent Events stream that says "this
  tournament just changed", and nothing else.

  ## Why it exists

  The public pages are static documents that poll themselves every 20
  seconds (10 while a round's results are coming in - see the root layout's
  refresher). Every hop before that poll is fast: OpenPairings sends a
  publish about two seconds after the arbiter's click, and this server stores
  it, moves `LatestIdCache` and broadcasts on `OpenResults.TournamentEvents`
  within milliseconds. The poll was the whole wait. Measured on 2026-10-03,
  an arbiter's "unpublish results" took 15 seconds to show, and a round's
  pairings could take up to 22 - two seconds of sending plus however long was
  left of a 20-second poll.

  So an open page also holds this stream. A publish sends one `data:` line;
  the page's script answers it by polling at once (with a fraction of a
  second's random spread, so a hall full of phones does not arrive in the
  same millisecond). The page itself does not change: it is still fetched,
  revalidated and cached exactly as before, and the poll keeps running
  underneath as the fallback for a browser without `EventSource`, a stream
  the proxy dropped, or a server that was full.

  ## What it says

  Only "changed". No snapshot, no id, no data a hidden tournament could leak
  through: the reader re-asks the page's own URL, the same door as every
  other request, and `OpenResultsWeb.Plugs.Visibility` answers that. A
  tournament that becomes hidden while streams are open gets one last
  "changed" (so the pages ask, and get their 404) and the streams close.

  An unknown slug, an unpublished one and a hidden one all get the same
  plain 404 - `OpenResultsWeb.VisibilityTest` holds it to that.

  ## Keeping it cheap and bounded

    * A comment line every 25 seconds, so Cloudflare (which drops a quiet
      connection after 100) keeps it open, and a reader who left is noticed
      by the next write failing rather than never.
    * `no-transform` in `cache-control`, which keeps Bandit and Cloudflare from
      compressing - a gzip stream buffers, and a buffered event arrives late.
    * Closed after half an hour; the browser reconnects on its own after the
      `retry:` delay. A stream nobody is reading cannot outlive that.
    * At most `max_streams` open at once (default 2000), counted in the
      `OpenResults.EventStreams` registry - which forgets a process the
      moment it dies, however it dies. Past that the answer is `503`, and the
      page simply keeps polling.
    * The page closes its stream while its tab is in the background, and
      opens it again when it comes back.

  The connection that served a stream can go on to serve the next request
  on the same keep-alive connection, so the subscription and the registry
  entry are both dropped before this returns.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.TournamentEvents
  alias OpenResultsWeb.Plugs.Visibility

  @registry OpenResults.EventStreams

  @defaults [
    heartbeat: :timer.seconds(25),
    lifetime: :timer.minutes(30),
    max_streams: 2_000,
    retry: 3_000
  ]

  def stream(conn, %{"slug" => slug}) do
    cond do
      not open?(slug) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found\n")

      Registry.count(@registry) >= setting(:max_streams) ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("retry-after", "60")
        |> send_resp(503, "Busy\n")

      true ->
        serve(conn, slug)
    end
  end

  # What every public page of the tournament would answer 200 for - see
  # `OpenResults.Tournaments` for the statuses.
  defp open?(slug), do: Visibility.visibility(slug) in [:pending, :listed]

  defp serve(conn, slug) do
    :ok = TournamentEvents.subscribe(slug)
    {:ok, _owner} = Registry.register(@registry, :stream, slug)

    try do
      conn =
        conn
        |> put_resp_content_type("text/event-stream", nil)
        |> put_resp_header("cache-control", "no-cache, no-transform")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      deadline = now() + setting(:lifetime)

      case chunk(conn, "retry: #{setting(:retry)}\n\n") do
        {:ok, conn} -> listen(conn, slug, deadline)
        {:error, _closed} -> conn
      end
    after
      TournamentEvents.unsubscribe(slug)
      Registry.unregister(@registry, :stream)
      flush(slug)
    end
  end

  defp listen(conn, slug, deadline) do
    left = deadline - now()

    receive do
      {:tournament_changed, ^slug} ->
        # Several publishes in a row are one poll for the reader.
        flush(slug)

        case chunk(conn, "data: changed\n\n") do
          {:ok, conn} -> if open?(slug), do: listen(conn, slug, deadline), else: conn
          {:error, _closed} -> conn
        end
    after
      max(min(setting(:heartbeat), left), 0) ->
        if left <= setting(:heartbeat), do: conn, else: keep_alive(conn, slug, deadline)
    end
  end

  defp keep_alive(conn, slug, deadline) do
    case chunk(conn, ": keep-alive\n\n") do
      {:ok, conn} -> listen(conn, slug, deadline)
      {:error, _closed} -> conn
    end
  end

  defp flush(slug) do
    receive do
      {:tournament_changed, ^slug} -> flush(slug)
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp setting(key) do
    :openresults
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
