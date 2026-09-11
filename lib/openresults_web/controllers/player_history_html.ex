defmodule OpenResultsWeb.PlayerHistoryHTML do
  @moduledoc """
  The markup for `OpenResultsWeb.PlayerHistoryController`.

  Thin on purpose: every fact here was already decided by
  `OpenResultsWeb.PlayerHistory`, which is where the display-rule and
  takedown logic lives. This module only prints what it was handed.
  """

  use OpenResultsWeb, :html

  alias OpenResultsWeb.TournamentHTML

  embed_templates "player_history_html/*"

  @doc """
  The heading name: the player's own name as the most recent tournament
  recorded it, or the FIDE id alone when nothing has matched yet.

  Never a name manufactured from the id - if nothing published it, this page
  has nothing to call the player but the number in its own address.
  """
  def heading(fide_id, []), do: "FIDE #{fide_id}"
  def heading(_fide_id, [entry | _newest_first]), do: entry.player_name

  @doc "One entry's dates, reusing the same rendering the masthead uses."
  def dates(entry) do
    TournamentHTML.dates(%{"start_date" => entry.start_date, "end_date" => entry.end_date})
  end

  @doc "One entry's placing, or `nil` when the tournament withheld it."
  def placing(%{rank: rank, points: points, total: total})
      when is_integer(rank) and not is_nil(total) do
    gettext("rank %{rank} of %{total}, on %{points}",
      rank: rank,
      total: total,
      points: TournamentHTML.number(points)
    )
  end

  def placing(_no_rank), do: nil
end
