defmodule OpenResultsWeb.EventHTML do
  @moduledoc """
  The markup for `OpenResultsWeb.EventController`: one card per tournament of
  the event.

  A card says what the tournament's own pages would, and no more: its
  players are counted only because its player list is public, and the round
  it is in is the newest round its arbiter has published.
  """

  use OpenResultsWeb, :html

  alias OpenResultsWeb.Tournament
  alias OpenResultsWeb.TournamentHTML

  embed_templates "event_html/*"

  @doc "The newest published round's number, or nil before round 1."
  def latest_round(payload) do
    case List.last(Tournament.rounds(payload)) do
      %{"number" => n} when is_integer(n) -> n
      _none -> nil
    end
  end

  @doc "\"Round 3 of 9\", \"Round 3\", or nil before any round is public."
  def round_line(payload) do
    count = Tournament.rounds_count(payload)

    case latest_round(payload) do
      nil -> nil
      n when count >= n -> gettext("Round %{number} of %{count}", number: n, count: count)
      n -> gettext("Round %{number}", number: n)
    end
  end

  @doc "How many rounds have every result in and public."
  def rounds_played(payload) do
    payload
    |> Tournament.rounds()
    |> Enum.count(fn round ->
      boards = Tournament.boards(round)
      boards != [] and Enum.all?(boards, &(is_binary(&1["result"]) and &1["result"] != ""))
    end)
  end
end
