defmodule OpenResultsWeb.SitemapController do
  @moduledoc """
  `GET /sitemap.xml` - the pages a search engine is welcome to find.

  Exactly the tournaments the front page lists, by the same two filters
  (`visible_only` for moderation, `Tournament.listed?/1` for the arbiter's
  own choice), so an unlisted tournament is not advertised here either. For
  each one: its standings, its cross-table and its rounds, each only when the
  arbiter publishes that page. Player cards are left out on purpose - a
  sitemap full of people's names is an index of people, and that is not
  something this site sets out to build.

  `lastmod` is the current snapshot's date: the pages of a tournament change
  when it publishes and at no other time.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Snapshots
  alias OpenResultsWeb.Tournament

  def show(conn, _params) do
    tournaments =
      Enum.filter(Snapshots.list_current(visible_only: true), &Tournament.listed?(&1.payload))

    urls =
      [{url(~p"/"), nil}, {url(~p"/terms"), nil}] ++
        Enum.flat_map(tournaments, &tournament_urls/1)

    body = [
      ~s(<?xml version="1.0" encoding="utf-8"?>\n),
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
      Enum.map(urls, &entry/1),
      "</urlset>\n"
    ]

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  defp tournament_urls(snapshot) do
    slug = snapshot.tournament_slug
    payload = snapshot.payload
    lastmod = lastmod(snapshot)

    standings = if Tournament.show?(payload, "standings"), do: [url(~p"/t/#{slug}")], else: []

    crosstable =
      if Tournament.crosstable?(payload), do: [url(~p"/t/#{slug}/crosstable")], else: []

    rounds =
      if Tournament.show?(payload, "pairings"),
        do: for(n <- Tournament.round_numbers(payload), do: url(~p"/t/#{slug}/round/#{n}")),
        else: []

    for loc <- standings ++ crosstable ++ rounds, do: {loc, lastmod}
  end

  defp entry({loc, nil}), do: ["  <url><loc>", esc(loc), "</loc></url>\n"]

  defp entry({loc, lastmod}),
    do: ["  <url><loc>", esc(loc), "</loc><lastmod>", lastmod, "</lastmod></url>\n"]

  defp lastmod(snapshot) do
    case snapshot.published_at || snapshot.received_at do
      %DateTime{} = at -> at |> DateTime.to_date() |> Date.to_iso8601()
      _unknown -> nil
    end
  end

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
