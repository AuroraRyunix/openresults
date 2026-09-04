defmodule OpenResultsWeb.TournamentController do
  @moduledoc """
  The public pages: standings, one round, one player.

  Each action does the same three things - fetch the current snapshot, refuse
  what is not in it, hand the payload to a template. There is no query beyond
  `Snapshots.latest/1`, because everything a page shows was decided on the
  arbiter's machine and travelled whole.

  A 404 here is a real answer, not a failure. An unpublished round is absent
  from the payload, so `/round/4` on a tournament whose arbiter has published
  rounds 1-3 and 5 has nothing to render, and saying "not published" is more
  honest than an empty table that looks like a round nobody turned up to.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Snapshots
  alias OpenResultsWeb.Tournament

  @doc """
  `GET /` - the tournaments that have published.
  """
  def index(conn, _params) do
    # Filtered here rather than in `Snapshots.list_current/0`: which
    # tournaments exist is a storage question and which ones are advertised is
    # a presentation one. A storage function that silently omits rows is a
    # trap for the next caller - a takedown sweep or an admin view would
    # quietly skip every unlisted tournament and give no reason.
    listed = Enum.filter(Snapshots.list_current(), &Tournament.listed?(&1.payload))

    render(conn, :index, page_title: "Tournaments", snapshots: listed)
  end

  @doc """
  `GET /t/:slug` - the standings, exactly as the arbiter computed them.
  """
  def standings(conn, %{"slug" => slug}) do
    with_payload(conn, slug, fn payload ->
      if Tournament.show?(payload, "standings") do
        render_standings(conn, payload, slug)
      else
        withheld(conn, payload, slug, "standings")
      end
    end)
  end

  defp render_standings(conn, payload, slug) do
    render(conn, :standings,
      page_title: Tournament.name(payload),
      payload: payload,
      slug: slug,
      current: :standings
    )
  end

  @doc """
  `GET /t/:slug/round/:n` - one round's pairings and byes.

  `?display=1` reaches the projector view of the same round rather than a
  route of its own: it is the same document and the same 404s, read from
  across a hall instead of a desk. See `TournamentHTML.projector_round/1` for
  what that renders.
  """
  def round(conn, %{"slug" => slug, "n" => n} = params) do
    with_payload(conn, slug, fn payload ->
      if Tournament.show?(payload, "pairings") do
        render_round(conn, payload, slug, n, display?(params))
      else
        withheld(conn, payload, slug, "round pairings")
      end
    end)
  end

  defp render_round(conn, payload, slug, n, display?) do
    number = integer(n)

    case number && Tournament.round(payload, number) do
      nil ->
        not_found(
          conn,
          "Round #{n} of #{Tournament.name(payload)} has not been published.",
          back: ~p"/t/#{slug}"
        )

      round ->
        render(conn, :round,
          page_title: "#{Tournament.name(payload)} - round #{number}",
          payload: payload,
          slug: slug,
          round: round,
          players: Tournament.players_by_no(payload),
          current: {:round, number},
          display?: display?
        )
    end
  end

  # Anything else - unset, "0", a stray value - is the ordinary page. Being
  # picky here rather than truthy-checking any presence at all means a URL
  # copied with `?display=` left blank, or a future `?display=list`, does not
  # silently land somebody on the projector view.
  defp display?(params), do: params["display"] in ["1", "true"]

  @doc """
  `GET /t/:slug/player/:no` - one player's card.

  `:no` is the tournament pairing number, the TRF start number. It is the only
  handle the document offers, and it means nothing outside this event, which
  is the point.
  """
  def player(conn, %{"slug" => slug, "no" => no}) do
    with_payload(conn, slug, fn payload ->
      # Links to a page the arbiter has switched off are not rendered, but a
      # link is a courtesy and a bookmarked or guessed URL is not. This is the
      # enforcement, and it is why every page in the `:pages` group is checked
      # in the controller rather than only in the markup.
      if Tournament.show?(payload, "player_cards") do
        render_player(conn, payload, slug, no, integer(no))
      else
        withheld(conn, payload, slug, "player cards")
      end
    end)
  end

  # Not a 404: the tournament is right there, and telling somebody it does not
  # exist sends them hunting for a link that was never broken. The arbiter has
  # chosen not to publish this part of it, which is a different thing and worth
  # saying.
  defp withheld(conn, payload, slug, what) do
    conn
    |> put_status(:not_found)
    |> put_view(html: OpenResultsWeb.TournamentHTML)
    |> render(:not_found,
      page_title: Tournament.name(payload),
      message: "#{Tournament.name(payload)} does not publish #{what}.",
      back: ~p"/t/#{slug}"
    )
  end

  defp render_player(conn, payload, slug, no, number) do
    case number && Tournament.player(payload, number) do
      nil ->
        not_found(
          conn,
          "#{Tournament.name(payload)} has no player #{no}.",
          back: ~p"/t/#{slug}"
        )

      player ->
        render(conn, :player,
          page_title: "#{Map.get(player, "name")} - #{Tournament.name(payload)}",
          payload: payload,
          slug: slug,
          player: player,
          card: Tournament.card(payload, number),
          current: {:player, number}
        )
    end
  end

  defp with_payload(conn, slug, render_fun) do
    case Snapshots.latest(slug) do
      nil ->
        not_found(conn, "No tournament has published under #{slug}.", back: ~p"/")

      snapshot ->
        render_fun.(snapshot.payload)
    end
  end

  defp not_found(conn, message, back: back) do
    conn
    |> put_status(:not_found)
    |> render(:not_found, page_title: "Not found", message: message, back: back)
  end

  # A pairing number or a round number, or `nil` for anything else. Whole
  # string only: `"3x"` is not round 3, and `String.to_integer/1` would raise
  # on it where a 404 is the right answer.
  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end
end
