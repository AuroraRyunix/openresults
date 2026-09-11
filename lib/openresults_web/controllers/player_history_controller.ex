defmodule OpenResultsWeb.PlayerHistoryController do
  @moduledoc """
  `GET /players/:fide_id` - one player, across every tournament published
  here.

  Unlike `OpenResultsWeb.TournamentController`, this page is not about one
  snapshot - it walks every current one looking for a FIDE id. A FIDE id
  that matches nothing is not a 404: any positive integer is a legitimate
  address for this route, the same way an empty front page is not a 404
  either. It reads as "nothing published here yet", not "this does not
  exist". A path segment that is not a FIDE id at all - letters, a negative
  number, punctuation - IS a 404: that address could never have meant
  anything.
  """

  use OpenResultsWeb, :controller

  alias OpenResultsWeb.Meta
  alias OpenResultsWeb.PlayerHistory

  def show(conn, %{"fide_id" => raw}) do
    case parse_fide_id(raw) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: OpenResultsWeb.TournamentHTML)
        |> render(:not_found,
          page_title: gettext("Not found"),
          page_description: Meta.not_found(),
          message: gettext("%{value} is not a FIDE id.", value: raw),
          back: ~p"/"
        )

      fide_id ->
        entries = PlayerHistory.for_fide_id(fide_id)

        render(conn, :show,
          page_title: page_title(fide_id, entries),
          page_description: Meta.player_history(fide_id, entries),
          fide_id: fide_id,
          entries: entries
        )
    end
  end

  defp page_title(fide_id, [entry | _newest_first]),
    do: "#{entry.player_name} - FIDE #{fide_id}"

  defp page_title(fide_id, []), do: "FIDE #{fide_id}"

  # A whole, positive number and nothing else - `"1503014x"` is not a FIDE
  # id, and `String.to_integer/1` would raise on it where a 404 is the right
  # answer. Zero and negative numbers are rejected too: FIDE ids start at 1
  # and a payload can never carry one that does not, so no snapshot could
  # ever match and the honest answer is "not a FIDE id" rather than a
  # perpetually empty list.
  defp parse_fide_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _not_a_positive_integer -> nil
    end
  end
end
