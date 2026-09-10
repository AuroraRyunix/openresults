defmodule OpenResultsWeb.Meta do
  @moduledoc """
  What a link to one of these pages says when it is pasted somewhere else.

  Club WhatsApp groups and Facebook posts are how people actually find this
  site, and until this existed a link rendered as a bare URL: no title beyond
  "OpenResults", no sentence, nothing saying which tournament or which round.
  Somebody forwarding the standings had to type that themselves.

  ## Nothing new is computed here

  Every sentence is assembled from values the snapshot already carries and
  the same accessors the pages themselves use - the tournament's name, the
  round the standings were taken after, a player's rank and points. A
  description that worked something out would be a second opinion about the
  tournament, and this app does not have opinions about tournaments.

  ## The display switches are not decoration

  `city` and `dates` are ticks an arbiter can turn off, and the front page
  once printed both after every other page had stopped - the comment in
  `index.html.heex` is about exactly that bug. A meta description is a worse
  place for the same mistake: it travels off the site entirely, into a chat
  app, where nobody who could notice will ever see it. So the two facts an
  arbiter can withhold pass through `Tournament.show?/2` here as well, and
  nothing else about the tournament is ever put in a description.

  Ratings, titles, clubs and federations are not here at all. A player's name
  and their placing are what a card is about; every other field they might
  have hidden simply never reaches this module.
  """

  use Gettext, backend: OpenResultsWeb.Gettext

  alias OpenResultsWeb.Tournament
  alias OpenResultsWeb.TournamentHTML

  @doc "The front page."
  def index do
    gettext(
      "Live chess results published by arbiters: standings, round pairings and a card for every player."
    )
  end

  @doc "The standings page - the one that gets shared."
  def standings(payload) do
    case Tournament.standings(payload)["after_round"] do
      round when is_integer(round) ->
        gettext("Standings after round %{round} of %{tournament}.",
          round: round,
          tournament: Tournament.name(payload)
        )

      _not_stated ->
        gettext("Standings of %{tournament}.", tournament: Tournament.name(payload))
    end
    |> with_where(payload)
  end

  @doc """
  The cross-table.

  No round number in it, deliberately. The published rounds can have gaps -
  an arbiter who has posted 1, 2, 3 and 5 is the fixture this repo tests
  against - so "after round 5" would be a claim the grid does not make.
  `standings.after_round` is not the answer either: it is about the placings,
  and this page has none.
  """
  def crosstable(payload) do
    gettext("Every published result of %{tournament}, round by round, as one cross-table.",
      tournament: Tournament.name(payload)
    )
    |> with_where(payload)
  end

  @doc """
  One round.

  `Tournament.round_heading/2` rather than the bare number, so a match-format
  event says "Match 2, game 1" here exactly as it does in the heading a
  reader will see when they follow the link.
  """
  def round(payload, number) do
    gettext("Pairings - %{round}, %{tournament}.",
      round: Tournament.round_heading(payload, number),
      tournament: Tournament.name(payload)
    )
    |> with_where(payload)
  end

  @doc """
  One player's card.

  Their placing when the standings carry one, their name and the tournament
  when they do not - a player entered but not yet placed is the ordinary case
  before round one.
  """
  def player(payload, player) do
    name = Map.get(player, "name") || gettext("Player %{number}", number: Map.get(player, "no"))

    case Tournament.standings_row(payload, Map.get(player, "no")) do
      nil ->
        gettext("%{player} in %{tournament}.", player: name, tournament: Tournament.name(payload))

      row ->
        gettext("%{player} - score %{points}, place %{rank} of %{total}, %{tournament}.",
          player: name,
          points: TournamentHTML.number(row["points"]),
          rank: row["rank"],
          total: length(Tournament.standings_rows(payload)),
          tournament: Tournament.name(payload)
        )
    end
  end

  @doc "A page the arbiter has switched off. Says the tournament exists, and no more."
  def withheld(payload) do
    gettext("%{tournament} on OpenResults.", tournament: Tournament.name(payload))
  end

  @doc "The entry form."
  def register(payload) do
    gettext(
      "Send your details to the arbiter of %{tournament}. They decide who plays; this form only carries the message.",
      tournament: Tournament.name(payload)
    )
  end

  @doc "The page after an entry has been queued."
  def received(payload) do
    gettext("Your entry for %{tournament} is with the arbiter.",
      tournament: Tournament.name(payload)
    )
  end

  @doc "Entries shut."
  def entries_closed, do: gettext("This tournament is no longer taking entries here.")

  @doc "The rate limiter's page."
  def too_many, do: gettext("Too many entries have arrived from this connection.")

  @doc "The page for a tournament whose queue is full."
  def queue_full,
    do: gettext("This form is holding as many entries as it can and is not taking more just now.")

  @doc "Anything that is not here."
  def not_found, do: gettext("This page is not published here.")

  # City and dates, each behind the arbiter's own tick, appended to a
  # sentence that is already complete without them. Empty is the ordinary
  # answer for a club event and for any tournament whose arbiter said no.
  defp with_where(sentence, payload) do
    info = Tournament.info(payload)

    [
      Tournament.show?(payload, "city") && info["city"],
      Tournament.show?(payload, "dates") && TournamentHTML.dates(info)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> sentence
      parts -> sentence <> " " <> Enum.join(parts, ", ") <> "."
    end
  end
end
