defmodule OpenResultsWeb.FeedController do
  @moduledoc """
  `GET /t/:slug/feed.xml` - one tournament as an Atom feed.

  A way to follow a tournament without an account, a push service or a
  cookie: a feed reader polls this the same way the page refresher polls the
  standings, and a new entry appears when the arbiter publishes something a
  reader would want to be told about.

  ## Entries are states, not publishes

  The snapshot table keeps every publish, but a publish is not news - an
  arbiter fixing a typo in a club name publishes too. So an entry is a state
  the tournament reached, named in its id:

    * `round-N-pairings` - round N's pairings are out;
    * `round-N-results` - every board of round N has a result, and its
      results are public;
    * `standings-N` - the standings now reflect round N.

  A feed reader dedupes by id, so re-publishing the same state is invisible
  and reaching a new one is exactly one new item. Nothing is calculated to
  get there: each state is read off the current snapshot with the same
  accessors the pages use.

  Every entry carries the current snapshot's time as `updated`. The server
  does not know when a round first appeared without walking the whole
  history, and inventing a time would be a claim the snapshot does not make.

  ## The display switches still hold

  Pairings entries only when the arbiter publishes pairings, a standings
  entry only when they publish standings, and a withheld round's results are
  never announced as complete. The titles are `OpenResultsWeb.Meta`'s
  sentences, which already honour the city and date ticks.

  A hidden tournament answers the same 404 as one that never published -
  `Tournaments.public_latest/1` says `nil` for both.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Tournaments
  alias OpenResultsWeb.Meta
  alias OpenResultsWeb.Tournament

  def show(conn, %{"slug" => slug}) do
    case Tournaments.public_latest(slug) do
      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found\n")

      snapshot ->
        conn
        |> put_resp_content_type("application/atom+xml")
        |> put_resp_header("cache-control", "private, no-cache")
        |> send_resp(200, atom(slug, snapshot))
    end
  end

  defp atom(slug, snapshot) do
    payload = snapshot.payload
    home = url(~p"/t/#{slug}")
    updated = timestamp(snapshot)

    entries =
      payload
      |> entries(slug)
      |> Enum.map(fn {id, title, href} ->
        """
          <entry>
            <id>#{esc(home)}##{esc(id)}</id>
            <title>#{esc(title)}</title>
            <link rel="alternate" type="text/html" href="#{esc(href)}"/>
            <updated>#{updated}</updated>
            <summary>#{esc(title)}</summary>
          </entry>
        """
      end)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <id>#{esc(home)}</id>
      <title>#{esc(Tournament.name(payload))}</title>
      <link rel="alternate" type="text/html" href="#{esc(home)}"/>
      <link rel="self" type="application/atom+xml" href="#{esc(url(~p"/t/#{slug}/feed.xml"))}"/>
      <updated>#{updated}</updated>
      <author><name>OpenResults</name></author>
      <generator>OpenResults</generator>
    #{entries}</feed>
    """
  end

  # Newest first: the standings, then rounds from the last one down, a
  # round's results above its pairings.
  defp entries(payload, slug) do
    standings =
      with true <- Tournament.show?(payload, "standings"),
           false <- Tournament.starting_rank?(payload),
           round when is_integer(round) <- Tournament.after_round(payload) do
        [{"standings-#{round}", Meta.standings(payload), url(~p"/t/#{slug}")}]
      else
        _nothing_to_say -> []
      end

    rounds =
      if Tournament.show?(payload, "pairings") do
        for %{"number" => n} = round <- Enum.reverse(Tournament.rounds(payload)),
            is_integer(n),
            entry <- round_entries(payload, slug, round, n),
            do: entry
      else
        []
      end

    standings ++ rounds
  end

  defp round_entries(payload, slug, round, n) do
    href = url(~p"/t/#{slug}/round/#{n}")
    pairings = {"round-#{n}-pairings", Meta.round(payload, n), href}

    if complete?(round) do
      [{"round-#{n}-results", Meta.round_results(payload, n), href}, pairings]
    else
      [pairings]
    end
  end

  defp complete?(round) do
    {reported, total} = Tournament.results_progress(round)
    Tournament.results_public?(round) and total > 0 and reported == total
  end

  defp timestamp(snapshot) do
    (snapshot.published_at || snapshot.received_at || DateTime.utc_now())
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
