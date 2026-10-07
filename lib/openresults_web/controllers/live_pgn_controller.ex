defmodule OpenResultsWeb.LivePgnController do
  @moduledoc """
  `GET /t/:slug/live/:round/:board/pgn` - the game on one board as a PGN file.

  Built on every request from the stored game, at the tournament's broadcast
  delay, through the same tile the page draws - so the file can never show a
  move, a result or a name the page would not. The tournament's headers come
  from the published snapshot and follow the same display ticks.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.LiveBoards.Pgn
  alias OpenResults.Tournaments
  alias OpenResultsWeb.LiveBoardsData

  def show(conn, %{"slug" => slug, "round" => round, "board" => board}) do
    with {round, ""} <- Integer.parse(round),
         {board, ""} <- Integer.parse(board),
         %{payload: payload} <- Tournaments.public_latest(slug),
         %{view: %{} = view} = tile <- LiveBoardsData.tile(payload, slug, round, board) do
      pgn = Pgn.build(view, LiveBoardsData.pgn_tags(payload, tile))

      conn
      |> put_resp_content_type("application/x-chess-pgn", "utf-8")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename(slug)}-round#{round}-board#{board}.pgn")
      )
      # A game that is still being played changes under this URL.
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, pgn)
    else
      _no_such_game -> conn |> put_status(:not_found) |> text("No such game.\n")
    end
  end

  defp filename(slug), do: String.replace(slug, ~r/[^A-Za-z0-9._-]/, "_")
end
