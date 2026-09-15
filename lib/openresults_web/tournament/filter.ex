defmodule OpenResultsWeb.Tournament.Filter do
  @moduledoc """
  Applying `OpenResultsWeb.FilterParams` to one tournament's own rows.

  `OpenResultsWeb.Tournament` reads the payload; this module reads a
  payload AND a parsed filter/sort together, and decides which rows a page
  shows and in what order. Nothing here talks HTTP or HEEx - the filter
  bar's markup lives in `OpenResultsWeb.Components.FilterBar`, and the
  query string it submits is `OpenResultsWeb.FilterParams`'s job.

  ## Categories, and the two different things that word means here

  `standings.rows[].category` (and `players[].category`) is the ONE
  category OpenPairings paired this player by - see
  `PairingsEngine.Categories.pairing_category/2` on that side. It is a
  single value and it already has a column on the standings table.

  `tournament.categories` / `players[].categories` is a different, richer
  list: every category a player carries, in the tournament's own order,
  gated on the arbiter's "Categories" display setting - see
  `docs/snapshot-schema.md`. THIS is what the filter bar's Category control
  offers and matches against, because a player can be in more than one
  group ("U1800" and "Women", say) and a spectator filtering for either one
  wants to find them. Matching against the single pairing category instead
  would silently miss every player whose prize category is not also the
  one they were paired by.
  """

  alias OpenResultsWeb.FilterParams
  alias OpenResultsWeb.Tournament

  @doc """
  The tournament's own category vocabulary, in its own order - `[]` when
  absent (older OpenPairings, or the arbiter has categories hidden). This
  is the ONLY thing that decides whether the Category control is offered at
  all; see the moduledoc on `docs/snapshot-schema.md`'s `tournament.categories`
  entry for the gating rule.
  """
  @spec categories(map()) :: [String.t()]
  def categories(payload) do
    case Map.get(Tournament.info(payload), "categories") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _absent_or_wrong_shape -> []
    end
  end

  @doc """
  `player`'s categories, in the tournament's own order - `players[].categories`
  when present, else `players[].category` wrapped in a one-element list
  (`[]` when that is also absent), exactly the fallback
  `docs/snapshot-schema.md` documents for a payload where the richer field
  is missing but the single pairing category is not.
  """
  @spec player_categories(map() | nil) :: [String.t()]
  def player_categories(%{"categories" => list}) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  def player_categories(%{"category" => category}) when is_binary(category) and category != "",
    do: [category]

  def player_categories(_no_categories_or_no_player), do: []

  @doc """
  The distinct, non-blank values of `key` among this tournament's players,
  sorted - `[]` when fewer than two distinct values exist, the same "a
  control that would filter nothing is not offered" rule the site's other
  dropdowns already follow (see `TournamentHTML`'s `distinct_values/1`).
  """
  @spec player_values(map(), String.t()) :: [String.t()]
  def player_values(payload, key) do
    payload
    |> Tournament.players()
    |> Enum.map(&Map.get(&1, key))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [_only_one] -> []
      several_or_none -> several_or_none
    end
  end

  @doc """
  Whether `player` matches every ACTIVE filter in `filters`. An unset
  filter matches everyone - this is `and`-composed across category, club,
  federation and the name search, so a reader narrowing by more than one
  control gets the intersection, not the union.
  """
  @spec matches?(map(), FilterParams.t(), map() | nil) :: boolean()
  def matches?(payload, %FilterParams{} = filters, player) do
    if FilterParams.active?(filters) do
      # A missing player (should not happen - every board and standings row
      # references a real pairing number - but the payload is not this
      # app's own and a reference to nobody is handled the way every other
      # accessor here handles an absent key) matches nothing once a filter
      # is active, rather than raising on `player["..."]` below.
      is_map(player) and
        category_match?(payload, filters, player) and
        value_match?(filters.fed, player["federation"]) and
        value_match?(filters.club, player["club"]) and
        name_match?(filters.q, player["name"]) and
        team_match?(payload, filters, player)
    else
      # No filter active at all: everyone matches, including a row this
      # app cannot resolve to a player - the unfiltered page has always
      # rendered such a row, and "no filter is active" must not change that.
      true
    end
  end

  defp team_match?(_payload, %FilterParams{team: nil}, _player), do: true

  defp team_match?(payload, %FilterParams{team: wanted}, player) do
    case Tournament.player_team_no(payload, player["no"]) do
      nil -> false
      no -> Integer.to_string(no) == wanted
    end
  end

  @doc """
  The teams a filter bar's "Team" control offers, as `{no, label}` - `[]`
  when the tournament is not a team event, the same "a control that would
  filter nothing is not offered" rule `player_values/2` follows for
  club/federation.
  """
  @spec team_options(map()) :: [{integer(), String.t()}]
  def team_options(payload) do
    if Tournament.team_event?(payload) do
      payload
      |> Tournament.teams()
      |> Enum.sort_by(&Map.get(&1, "no"))
      |> Enum.map(&{Map.get(&1, "no"), Tournament.team_label(&1)})
    else
      []
    end
  end

  defp category_match?(_payload, %FilterParams{category: nil}, _player), do: true

  defp category_match?(payload, %FilterParams{category: wanted}, player) do
    # Belt and braces: `categories(payload)` is what decided whether the
    # control was offered at all. A filter naming a category the
    # tournament does not list (a stale link after the arbiter renamed
    # one) matches nobody rather than falling back to "everyone".
    wanted in categories(payload) and wanted in player_categories(player)
  end

  defp value_match?(nil, _actual), do: true
  defp value_match?(_wanted, nil), do: false
  defp value_match?(wanted, actual), do: wanted == actual

  defp name_match?(nil, _actual), do: true
  defp name_match?(_wanted, nil), do: false

  # Every word of the search, in any order, somewhere in the name, with
  # accents and case ignored on both sides. "Ilse De Vos" finds the arbiter's
  # "De Vos, Ilse", and "muller" finds "Müller" - the same rule the filter
  # bar's script applies to the rows while the reader is still typing (see
  # `OpenResultsWeb.Components.FilterBar`), so pressing Enter never turns a
  # row the reader could see into "No players match". The two are kept in
  # step by hand: a change here is a change there.
  defp name_match?(wanted, actual) do
    haystack = fold(actual)

    wanted
    |> fold()
    |> String.split(~r/[\s,]+/u, trim: true)
    |> Enum.all?(&String.contains?(haystack, &1))
  end

  @doc false
  # Lower case with the combining accents taken off - the NFD-and-strip the
  # script does with `normalize("NFD").replace(/[̀-ͯ]/g, "")`.
  def fold(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> case do
      binary when is_binary(binary) -> binary
      _invalid -> text
    end
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.downcase()
  end

  @doc """
  Standings rows, filtered and sorted for display, and the place-in-group
  numbering to go with them.

  Returns `%{rows: [row], places: %{no => place}}`. `rows` is `payload`'s
  own `standings.rows` (or `Tournament.starting_rank/1`'s starting-number
  list is NOT handled here - a tournament with no standings yet has nothing
  for this to filter), reduced to the ones `matches?/3` accepts and then
  reordered per `filters.sort` - `"rank"` (the default) leaves the arbiter's
  own order untouched, because that order already IS rank order; every
  other key does a STABLE sort (Elixir's `Enum.sort_by/2` is a stable merge
  sort), so two rows the arbiter placed level, or two with the same rating,
  keep whatever relative order they arrived in rather than swapping places
  between one render and the next.

  `places` is keyed by pairing number and built from the UNFILTERED rows in
  the arbiter's own order, restricted to the players who carry
  `filters.category` - never from the filtered-and-sorted list above, and
  never narrowed further by `fed`/`club`/`q` even when those are also
  active. "Place within category" is a question about the category alone;
  answering it from whatever else happens to be selected would make the
  same category and the same standings print a different 3rd-of-12 on two
  different links. Empty when no category filter is active - the caller
  only has a "Cat" number to show in that case.
  """
  @spec standings(map(), FilterParams.t()) :: %{rows: [map()], places: %{integer() => integer()}}
  def standings(payload, %FilterParams{} = filters) do
    players = Tournament.players_by_no(payload)
    rows = Tournament.standings_rows(payload)

    places =
      case filters.category do
        nil -> %{}
        wanted -> place_by_rank(rows, players, wanted)
      end

    shown =
      rows
      |> Enum.filter(&matches?(payload, filters, Map.get(players, &1["player"])))
      |> sort_rows(filters.sort, players)

    %{rows: shown, places: places}
  end

  defp place_by_rank(rows, players, wanted) do
    rows
    |> Enum.filter(&(wanted in player_categories(Map.get(players, &1["player"]))))
    |> Enum.map_reduce({:none, 0}, fn row, {prev_rank, place} ->
      place = if prev_rank == row["rank"], do: place, else: place + 1
      {{row["player"], place}, {row["rank"], place}}
    end)
    |> elem(0)
    |> Map.new()
  end

  defp sort_rows(rows, "rank", _players), do: rows

  defp sort_rows(rows, "rating", players) do
    Enum.sort_by(rows, fn row ->
      rating = get_in(players, [row["player"], "rating"])
      {is_nil(rating), -(rating || 0)}
    end)
  end

  defp sort_rows(rows, "name", players) do
    Enum.sort_by(rows, fn row ->
      String.downcase(get_in(players, [row["player"], "name"]) || "")
    end)
  end

  defp sort_rows(rows, "federation", players) do
    Enum.sort_by(rows, fn row ->
      federation = get_in(players, [row["player"], "federation"])
      {is_nil(federation), federation || ""}
    end)
  end

  @doc """
  A round's boards, in the arbiter's own board order, each tagged with
  whether it matches the active filters and which seat(s) do.

  Returns `[{board, %{shown?: boolean, white?: boolean, black?: boolean}}]`
  - `shown?` is true the moment EITHER seat matches, and `white?`/`black?`
  say which side to highlight for it. While NO filter is active every board
  is `shown?: true` (nothing to narrow down), but `white?` and `black?` are
  both `false` - there is nothing to highlight when nothing was searched
  for, and highlighting every seat on every board would say the opposite of
  what an empty filter means. Never reordered: a pairing sheet's board
  order is the arbiter's own numbering, and the brief this shipped from is
  explicit that sort does not apply here - see
  `OpenResultsWeb.Components.FilterBar`'s `sort?` attribute, which the round
  page passes as `false`.
  """
  @spec round_boards(map(), FilterParams.t(), [map()]) :: [{map(), map()}]
  def round_boards(payload, %FilterParams{} = filters, boards) do
    players = Tournament.players_by_no(payload)
    active? = FilterParams.active?(filters)

    Enum.map(boards, fn board ->
      white? = active? and matches?(payload, filters, Map.get(players, board["white"]))
      black? = active? and matches?(payload, filters, Map.get(players, board["black"]))
      {board, %{shown?: not active? or white? or black?, white?: white?, black?: black?}}
    end)
  end

  @doc """
  Cross-table rows, filtered - never reordered.

  `Tournament.crosstable/1` deliberately keeps its rows in starting-number
  order rather than rank order, so a reader who has just read an opponent
  number off a cell finds that row by counting rather than by rank - see
  its own moduledoc. Offering a `sort=` here would either silently ignore
  the request or override that deliberate order, so the crosstable page
  does not offer the sort control at all (`FilterBar`'s `sort?` is `false`
  here too); only the row SET changes, never the order the remaining rows
  are in. The opponent columns are untouched either way - only which rows
  appear is decided here, per the brief.
  """
  @spec crosstable_rows(map(), FilterParams.t(), [map()]) :: [map()]
  def crosstable_rows(payload, %FilterParams{} = filters, rows) do
    Enum.filter(rows, &matches?(payload, filters, &1.player))
  end
end
