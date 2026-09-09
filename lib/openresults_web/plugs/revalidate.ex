defmodule OpenResultsWeb.Plugs.Revalidate do
  @moduledoc """
  Answers "has this tournament changed since you last asked" without reading
  the tournament.

  ## The cost this removes

  Every page here is a plain request that loads the published snapshot and
  decodes it. On a 300-player, 11-round event that document is ~580 KB of
  JSON and the decode is about 17 ms of CPU - and the page refreshes itself
  every 20 seconds, per spectator, so a hall full of phones pays that
  repeatedly for a document that only changes when the arbiter publishes.

  The snapshot table appends one row per changed publish and collapses a
  byte-identical re-send, so **the newest row's id IS the version**. Asking
  for the id alone is a primary-key lookup; if the reader already has that
  id, the answer is `304 Not Modified` and the payload is never touched.

  ## Why not let the CDN hold it

  Cloudflare sits in front of this site and currently caches nothing
  (`cf-cache-status: DYNAMIC`), which is a real cost - but making the page
  publicly cacheable would mean a spectator could be handed a standings page
  that was correct thirty seconds ago, and there is no worse failure for a
  results site than a stuck page somebody trusts. Deliberately rejected by
  the maintainer on those grounds.

  So the header is `private, no-cache`: not "do not store", but "always ask
  first". The reader revalidates on every poll and gets the new page the
  instant it exists, while an unchanged one costs a primary-key lookup
  instead of half a megabyte of JSON.

  ## Why the tag is keyed

  The ETag is also the page cache's key, so two URLs that produce the same
  tag are one page as far as this site is concerned. It used to be a bare
  `phash2` of the path and query string - public, deterministic, unkeyed and
  27 bits wide - which meant a query string colliding with a target page's
  tag could be worked out offline in seconds, and the collision would then
  serve one page's body under the URL a legitimate reader asks for.

  It is now an HMAC under a value drawn once per boot, so there is nothing
  to compute against: the input nobody outside this node holds is the secret.
  Bounded even when it did collide - the tournament, the snapshot id and the
  locale are separate parts of the cache key, so a collision could never
  cross tournaments, outlive a publish or surface a 404 or a withheld page.
  Defacement inside one tournament, not disclosure.

  ## What is not covered

  Only the read routes for a published tournament. The entry form is a form,
  the registration and snapshot APIs are authenticated, and none of them
  wants a browser deciding it already knows the answer.
  """

  import Plug.Conn

  alias OpenResults.Snapshots
  alias OpenResultsWeb.Plugs.Revalidate.Page

  @secret {__MODULE__, :etag_secret}

  def init(opts), do: opts

  @doc """
  Draws this node's ETag secret. Called once, at boot, by
  `OpenResults.Application`.

  Once per boot and not once per request, because the tag is an HTTP
  validator as well as a cache key: a value that moved under a reader would
  answer 200 to every revalidation and switch this plug off. Stable for the
  life of a snapshot is the property that matters, and a restart changing it
  costs one fetch per reader - the page cache does not survive a restart
  either.
  """
  @spec new_secret() :: :ok
  def new_secret, do: :persistent_term.put(@secret, :crypto.strong_rand_bytes(32))

  def call(conn, _opts) do
    case conn.params["slug"] do
      slug when is_binary(slug) -> revalidate(conn, slug)
      _no_slug -> conn
    end
  end

  defp revalidate(conn, slug) do
    case Snapshots.latest_id(slug) do
      nil ->
        # Nothing published under this slug. The 404 that follows is not a
        # thing to cache, and there is no version to name.
        conn

      id ->
        locale = locale(conn)
        etag = etag_for(conn, id, locale)

        conn =
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, no-cache")

        cond do
          etag in request_etags(conn) ->
            conn |> send_resp(304, "") |> halt()

          body = Page.get(slug, id, locale, etag) ->
            conn
            |> put_resp_content_type("text/html")
            |> send_resp(200, body)
            |> halt()

          true ->
            register_before_send(conn, &keep(&1, slug, id, locale, etag))
        end
    end
  end

  # Set by `OpenResultsWeb.Plugs.Locale`, which the browser pipeline runs
  # before this one. The fallback is not decoration: this plug must not be
  # the thing that breaks if it is ever mounted somewhere that one is not.
  defp locale(conn), do: conn.assigns[:locale] || OpenResultsWeb.Locale.default()

  # Only a plain 200 of HTML. A redirect, a 404 or an error page is not this
  # document and must never be served in its place.
  defp keep(%{status: 200} = conn, slug, id, locale, etag) do
    if html?(conn), do: Page.put(slug, id, locale, etag, IO.iodata_to_binary(conn.resp_body))
    conn
  end

  defp keep(conn, _slug, _id, _locale, _etag), do: conn

  defp html?(conn) do
    conn
    |> get_resp_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "text/html"))
  end

  # The PATH is part of the identity, not just the snapshot - one document
  # renders as standings, as a round, and as a card per player, so a reader
  # moving from the standings to a player page must not be told that the page
  # they have not seen is unchanged. The QUERY STRING is now part of it too:
  # a round's own URL renders differently under `?display=1` (the projector
  # view), and without this a reader's `?display=1` request and somebody
  # else's plain one would share one ETag and shadow each other's page in
  # `Page` - whichever variant rendered first would be served to both.
  #
  # And the LOCALE, which is the one of the three that does not appear in the
  # URL at all: a reader whose browser asks for Dutch and a reader whose
  # browser asks for French request the same address and must not be handed
  # the same document. That matters here beyond the page cache - this string
  # goes to the browser as an HTTP validator, and a browser holding the Dutch
  # page must get a 200 rather than a 304 when it next asks in French.
  #
  # The path and the query string are the two an outsider chooses, so they go
  # through the MAC rather than a plain hash - see "Why the tag is keyed". The
  # id and the locale stay readable in front of it: they are already separate
  # parts of the cache key, and a tag one can read at a glance is worth
  # keeping for the afternoon somebody is reading a header dump.
  defp etag_for(conn, id, locale), do: ~s("#{id}-#{locale}-#{digest(conn)}")

  # `term_to_binary` rather than joining with a separator, because a separator
  # has to be a character that can appear in neither half, and this settles
  # that by construction. 16 bytes of a SHA-256 MAC: 128 bits is beyond any
  # collision search, and the rest would only make a header longer.
  defp digest(conn) do
    :hmac
    |> :crypto.mac(
      :sha256,
      secret(),
      :erlang.term_to_binary({conn.request_path, conn.query_string})
    )
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  defp secret do
    case :persistent_term.get(@secret, nil) do
      nil ->
        # Only reachable if this plug runs without the application having
        # started - a unit test, in practice. Drawing one here keeps that
        # case working; the boot path is what makes it one value per node.
        new_secret()
        :persistent_term.get(@secret)

      secret ->
        secret
    end
  end

  # `If-None-Match` may carry several, comma separated, and a cache is
  # allowed to return a weak validator (`W/"..."`) for one we sent strong.
  # Compared after stripping that prefix rather than by exact string, or a
  # revalidation through any intermediary would silently always miss.
  defp request_etags(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
  end
end
