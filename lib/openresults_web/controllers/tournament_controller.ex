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
    render(conn, :index,
      page_title: "Tournaments",
      snapshots: Snapshots.list_current()
    )
  end

  @doc """
  `GET /t/:slug` - the standings, exactly as the arbiter computed them.
  """
  def standings(conn, %{"slug" => slug}) do
    with_payload(conn, slug, fn payload ->
      render(conn, :standings,
        page_title: Tournament.name(payload),
        payload: payload,
        slug: slug,
        current: :standings
      )
    end)
  end

  @doc """
  `GET /t/:slug/round/:n` - one round's pairings and byes.
  """
  def round(conn, %{"slug" => slug, "n" => n}) do
    with_payload(conn, slug, fn payload ->
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
            current: {:round, number}
          )
      end
    end)
  end

  @doc """
  `GET /t/:slug/player/:no` - one player's card.

  `:no` is the tournament pairing number, the TRF start number. It is the only
  handle the document offers, and it means nothing outside this event, which
  is the point.
  """
  def player(conn, %{"slug" => slug, "no" => no}) do
    with_payload(conn, slug, fn payload ->
      number = integer(no)

      cond do
        # The arbiter has turned player cards off for this tournament. The
        # link is not rendered either, but a link is a courtesy and a
        # bookmarked or guessed URL is not - this is the enforcement.
        not Tournament.show?(payload, "player_cards") ->
          not_found(
            conn,
            "#{Tournament.name(payload)} does not publish player cards.",
            back: ~p"/t/#{slug}"
          )

        true ->
          render_player(conn, payload, slug, no, number)
      end
    end)
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
