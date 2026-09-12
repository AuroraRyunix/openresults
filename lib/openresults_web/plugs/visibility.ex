defmodule OpenResultsWeb.Plugs.Visibility do
  @moduledoc """
  Reads a tournament's visibility once, ahead of everything that renders it.

  On every route with a `:slug`, assigns `:tournament_visibility`:

    * `:none` - nothing has published under this slug. Unknown, or minted and
      not yet published; the two must look the same, so neither gets anything
      from this plug;
    * `:pending`, `:listed` or `:hidden` - what `OpenResults.Tournaments` says.

  `OpenResultsWeb.Plugs.Revalidate` reads it: it must not answer a 304 or
  serve a cached page for a hidden tournament, and it keys its ETag on the
  status so a browser holding the pending page (with `noindex`) is not told it
  is still current once the tournament is listed.

  For a PENDING tournament this also sets `X-Robots-Tag: noindex` and assigns
  `:noindex` for the layout's `<meta name="robots">`. Both, because a crawler
  that fetched the page and one that only looked at the headers must reach the
  same conclusion.

  A hidden tournament is not refused here. The 404 a hidden slug gets has to
  be the SAME 404 an unknown slug gets on that particular page - the standings
  page, the entry form and the FIDE search each word theirs differently - so
  each controller asks `OpenResults.Tournaments.public_latest/1`, which
  answers `nil` for both, and renders what it would for nothing at all. This
  plug adds nothing to a hidden tournament's response for the same reason.

  ## Cost

  The snapshot id first, the status only if there is one. For a published
  tournament both answers come from ETS (`LatestIdCache`, `StatusCache`), so
  the read path still does not touch the database. For a slug nothing
  published under, the id lookup is the same one query `Revalidate` always
  paid - and no status is looked up or cached, so a scanner walking random
  slugs cannot grow `StatusCache` one entry per guess.
  """

  import Plug.Conn

  alias OpenResults.Snapshots
  alias OpenResults.Tournaments

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.params["slug"] do
      slug when is_binary(slug) -> mark(conn, visibility(slug))
      _no_tournament -> conn
    end
  end

  @doc """
  `:none` when nothing has published under `slug`, otherwise its status.
  """
  @spec visibility(String.t()) :: :none | Tournaments.status()
  def visibility(slug) do
    case Snapshots.latest_id(slug) do
      nil -> :none
      _id -> Tournaments.status(slug)
    end
  end

  defp mark(conn, :pending) do
    conn
    |> assign(:tournament_visibility, :pending)
    |> assign(:noindex, true)
    |> put_resp_header("x-robots-tag", "noindex")
  end

  defp mark(conn, visibility), do: assign(conn, :tournament_visibility, visibility)
end
