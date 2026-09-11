defmodule OpenResultsWeb.PlayerHistory do
  @moduledoc """
  One player's appearances across every tournament this server has published,
  matched by FIDE id.

  Nothing here is stored. It is assembled on every request from
  `OpenResults.Snapshots.list_current/0` - one row per tournament this server
  currently holds - the same source the front page reads. There is no
  identity table and no cross-tournament player record: the FIDE id IS the
  join key, read straight out of `players[].fide_id` in each snapshot.

  ## Why FIDE id and never a name

  Names collide. Two "Jan Janssens" in two different clubs are two different
  people, and matching on the string would silently merge their histories -
  wrongly, and invisibly to whoever was reading it. A FIDE id is the one
  handle the contract carries that actually identifies a *person* rather
  than a *seat in one event* (`no` is the latter, and is meaningless outside
  the tournament that assigned it). A player with no FIDE id gets no history
  page and no link to one - see `OpenResultsWeb.TournamentHTML.player_link/1`
  and the player template, which only ever link here when `fide_id` is
  present.

  ## What is deliberately filtered out

  **Unlisted tournaments.** `listed?` controls the front page, and this is
  another listing - a search surface, not a single tournament's own address.
  A tournament an arbiter chose to hand out only as a direct link should not
  become findable by searching a player's FIDE id instead. This is a
  judgement call: the tournament's OWN page (`/t/:slug`) stays reachable
  either way, exactly as unlisting already promises: see `Tournament.listed?/1`.

  **A withheld placing.** When `display.standings` is off, the entry still
  appears - the tournament happened and this player played in it - but
  carries no rank, no points and no field size, the same withholding the
  standings page itself and the player card already apply.

  **A withheld card.** When `display.player_cards` is off, the entry is
  still listed but is not a link - the courtesy `player_link/1` already
  extends everywhere else on the site.

  **A taken-down tournament.** Not filtered here at all: `Takedown.purge/1`
  deletes every row for the slug, so it is simply absent from
  `list_current/0` and never reaches this module.

  Nothing is computed that was not already sent. A placing and a points total
  are read straight off `standings.rows`, the same fields the standings page
  itself renders - never re-derived, for the reason the schema doc gives
  everywhere else: the arbiter's screen and this site must never be able to
  disagree.
  """

  alias OpenResults.Snapshots
  alias OpenResultsWeb.Tournament

  @type entry :: %{
          slug: String.t(),
          name: String.t(),
          city: String.t() | nil,
          start_date: String.t() | nil,
          end_date: String.t() | nil,
          player_no: integer(),
          player_name: String.t() | nil,
          rank: integer() | nil,
          points: number() | nil,
          total: non_neg_integer() | nil,
          linkable?: boolean()
        }

  @doc """
  Every published, listed tournament whose player list carries `fide_id`,
  newest first by start date.

  `fide_id` is expected to already be a positive integer - see
  `OpenResultsWeb.PlayerHistoryController` for where a path parameter is
  parsed and rejected before it reaches here.
  """
  @spec for_fide_id(integer()) :: [entry()]
  def for_fide_id(fide_id) when is_integer(fide_id) do
    Snapshots.list_current()
    |> Enum.filter(&Tournament.listed?(&1.payload))
    |> Enum.map(&entry_for(&1.payload, fide_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&sort_key/1, :desc)
  end

  def for_fide_id(_not_a_fide_id), do: []

  defp entry_for(payload, fide_id) do
    case Enum.find(Tournament.players(payload), &(Map.get(&1, "fide_id") == fide_id)) do
      nil -> nil
      player -> build(payload, player)
    end
  end

  defp build(payload, player) do
    info = Tournament.info(payload)
    no = Map.get(player, "no")

    # `standings_row/2` is only consulted when the arbiter allows it - the
    # same tick `Tournament.card/2`'s opponent totals already honour. A row
    # that exists in the payload but is switched off here must read exactly
    # like a row that was never sent.
    row = Tournament.show?(payload, "standings") && Tournament.standings_row(payload, no)

    %{
      slug: Map.get(info, "slug"),
      name: Tournament.name(payload),
      city: Tournament.show?(payload, "city") && string(info, "city"),
      start_date: string(info, "start_date"),
      end_date: string(info, "end_date"),
      player_no: no,
      player_name: Map.get(player, "name"),
      rank: row && Map.get(row, "rank"),
      points: row && Map.get(row, "points"),
      total: row && length(Tournament.standings_rows(payload)),
      linkable?: Tournament.show?(payload, "player_cards")
    }
  end

  # Chronological, most recent first. `start_date` is an ISO date string, so
  # lexical order is chronological order; an absent one falls to the end
  # rather than sorting first, which a bare `nil` or `""` would do against
  # real dates.
  defp sort_key(%{start_date: date}) when is_binary(date) and date != "", do: date
  defp sort_key(_no_date), do: ""

  defp string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _absent_or_blank -> nil
    end
  end
end
