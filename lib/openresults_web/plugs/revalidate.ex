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

  ## What is not covered

  Only the read routes for a published tournament. The entry form is a form,
  the registration and snapshot APIs are authenticated, and none of them
  wants a browser deciding it already knows the answer.
  """

  import Plug.Conn

  alias OpenResults.Snapshots
  alias OpenResultsWeb.Plugs.Revalidate.Page

  def init(opts), do: opts

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
        etag = etag_for(conn, id)

        conn =
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, no-cache")

        cond do
          etag in request_etags(conn) ->
            conn |> send_resp(304, "") |> halt()

          body = Page.get(id, etag) ->
            conn
            |> put_resp_content_type("text/html")
            |> send_resp(200, body)
            |> halt()

          true ->
            register_before_send(conn, &keep(&1, id, etag))
        end
    end
  end

  # Only a plain 200 of HTML. A redirect, a 404 or an error page is not this
  # document and must never be served in its place.
  defp keep(%{status: 200} = conn, id, etag) do
    if html?(conn), do: Page.put(id, etag, IO.iodata_to_binary(conn.resp_body))
    conn
  end

  defp keep(conn, _id, _etag), do: conn

  defp html?(conn) do
    conn
    |> get_resp_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "text/html"))
  end

  # The PATH is part of the identity, not just the snapshot. One document
  # renders as standings, as a round, and as a card per player, so a reader
  # moving from the standings to a player page must not be told that the page
  # they have not seen is unchanged.
  defp etag_for(conn, id), do: ~s("#{id}-#{:erlang.phash2(conn.request_path)}")

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
