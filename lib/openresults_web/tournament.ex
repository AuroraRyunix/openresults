defmodule OpenResultsWeb.Tournament do
  @moduledoc """
  A published snapshot, read as a tournament.

  The only module that knows the shape of the document in
  `docs/snapshot-schema.md`. Everything here reads; nothing here decides. The
  arbiter's machine applied the tiebreaks, ordered the placings and set the
  bye values before it built the payload, so this app renders what it was
  given even where a number looks wrong. A server that corrected the arbiter
  would put the hall and the public page into disagreement, which is the one
  failure the contract exists to prevent.

  Every accessor tolerates an absent key. A payload is allowed to be older
  than the server reading it, so a missing `standings`, a round without
  `byes`, or a player without a rating is a tournament that has not got there
  yet rather than an error. Fields nobody here recognises are simply not
  looked at, which is the same rule the ingest side follows.
  """

  # Every result token the contract carries, and the points each seat scored,
  # as `{white, black}`.
  #
  # The token is read rather than interpreted: `"1-0"` states in its own two
  # halves what each side got, and so does every other token in the
  # vocabulary. Picking the half that belongs to a seat is not arithmetic an
  # arbiter could disagree with, which is what makes the running score on a
  # player card defensible when the contract deliberately carries no per-game
  # points.
  #
  # The legacy `+--` and `--+` spellings are deliberately absent. The publish
  # path normalises them to `1-0FF` and `0-1FF`, so accepting them here would
  # document a vocabulary that no longer travels.
  @result_points %{
    "1-0" => {1.0, 0.0},
    "0-1" => {0.0, 1.0},
    "1/2-1/2" => {0.5, 0.5},
    "1-0U" => {1.0, 0.0},
    "0-1U" => {0.0, 1.0},
    "1/2-1/2U" => {0.5, 0.5},
    "1/2-0" => {0.5, 0.0},
    "0-1/2" => {0.0, 0.5},
    "0-0" => {0.0, 0.0},
    "1-0FF" => {1.0, 0.0},
    "0-1FF" => {0.0, 1.0},
    "0-0FF" => {0.0, 0.0}
  }

  @doc """
  The `tournament` object, or an empty one.
  """
  def info(payload), do: object(payload, "tournament")

  @doc """
  Whether this tournament belongs in the front-page list.

  Absent means listed, which is what publishing meant before there was a
  choice. An arbiter unlists an event to hand out its link rather than
  advertise it - it stays perfectly readable to anyone holding the address,
  and the arbiter's own settings page says so in as many words, because
  reading "unlisted" as "private" is how somebody publishes an event they
  meant to keep off the web.
  """
  def listed?(payload) do
    case Map.get(info(payload), "listed") do
      false -> false
      _listed_or_unstated -> true
    end
  end

  @doc """
  Whether the arbiter allows `key` to be shown - `"rating"`, `"club"`,
  `"federation"`, `"title"`, `"category"`, `"tiebreaks"`, `"player_cards"`.

  **Absent means shown**, in every direction: a payload from before the
  field existed, a key this server knows that the arbiter's app has never
  heard of, and a key the arbiter's app sends that this server does not
  recognise. All three are the same answer, and it is the same answer this
  server gave before any of it existed.

  The failure directions are not symmetric. Showing a column an arbiter
  meant to hide is visible to them and fixed in one click; hiding one they
  meant to show is invisible from their side - their own screens look right
  - and surfaces as somebody in the hall asking where the ratings went.

  Note this is a display rule, not an access rule. It decides what a page
  renders. Nothing here is a substitute for not publishing data that should
  not leave the arbiter's machine.
  """
  def show?(payload, key) do
    case payload |> info() |> Map.get("display") do
      %{} = display ->
        case Map.get(display, key) do
          false -> false
          _shown_or_unstated -> true
        end

      _absent_or_junk ->
        true
    end
  end

  @doc """
  Whether the arbiter is accepting entries for this tournament.

  **An absent field means open**, which is the one place in this module where
  the tolerant default is not merely convenient but load-bearing.

  `registration_open` was added to the contract on 2026-08-29, when the
  arbiter's app stopped serving its own entry form and this became the only
  one. Every snapshot published before that date is silent on the question,
  and this server accepted entries for all of them - so reading silence as
  "open" is what those tournaments already do, and reading it as "closed"
  would shut every one of them the moment this deployed, without a word to
  the arbiter and without anything in the UI to explain it.

  The failure directions are not symmetric. An entry that should not have
  been taken lands in a queue an arbiter reads and rejects; a form that is
  shut when it should be open turns a real person away and tells nobody. So
  the tolerant reading is also the safe one.
  """
  def registration_open?(payload) do
    case Map.get(info(payload), "registration_open") do
      false -> false
      _open_or_unstated -> true
    end
  end

  @doc """
  The tournament's display name, falling back to its slug.
  """
  def name(payload) do
    info = info(payload)
    string(info, "name") || string(info, "slug") || "Tournament"
  end

  @doc """
  The pairing system: `"swiss"`, `"roundrobin"`, `"keizer"`, or whatever a
  newer client sent.
  """
  def system(payload), do: string(info(payload), "system")

  @doc """
  Whether the standings carry Keizer's columns instead of points and
  tiebreaks.

  Keyed off `system` rather than off which keys happen to be present on a row,
  because a row that is merely missing `tiebreaks` is an incomplete swiss row,
  not a Keizer one.
  """
  def keizer?(payload), do: system(payload) == "keizer"

  @doc """
  How many rounds the tournament has, published or not.
  """
  # Clamped, because this number comes from the payload and the payload comes
  # from whoever holds the ingest token. `round_slots/1` materialises
  # `1..rounds_count` and the masthead walks it, so a mistyped 1_000_000 costs
  # every anonymous reader seconds of CPU on every request, forever, from one
  # POST. Measured before clamping: 3.8 s for standings and 10.3 s for a
  # player card at a million.
  #
  # 100 is past any real event - the longest FIDE-rated Swiss on record is
  # nowhere near it - so a count above it is a typo or an attack, and either
  # way the honest answer is to ignore it rather than to serve it slowly.
  @max_rounds 100

  def rounds_count(payload) do
    case Map.get(info(payload), "rounds_count") do
      count when is_integer(count) and count >= 0 and count <= @max_rounds -> count
      _absent_or_implausible -> 0
    end
  end

  @doc """
  The rounds present in the payload, in number order.

  Published rounds and no others: a round the arbiter withheld was never sent.
  """
  def rounds(payload) do
    payload
    |> list("rounds")
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&number_of/1)
  end

  @doc """
  The numbers of the published rounds.
  """
  def round_numbers(payload) do
    payload
    |> rounds()
    |> Enum.map(&number_of/1)
    |> Enum.filter(&is_integer/1)
  end

  @doc """
  Every round the tournament has, published or not, in order.

  The union of `1..rounds_count` and whatever `rounds` actually contains, so a
  round arriving beyond the declared count still gets a slot rather than
  disappearing. What this is for is showing the gaps: a navigation strip that
  listed only the published rounds would make a withheld round look like a
  tournament that is one round shorter.
  """
  def round_slots(payload) do
    Enum.sort(Enum.uniq(Enum.to_list(1..rounds_count(payload)//1) ++ round_numbers(payload)))
  end

  @doc """
  Round `number`, or `nil` if it is not in the payload.

  `nil` is the whole withholding rule: an unpublished round is absent from the
  document, so there is nothing to filter and nothing to leak. The caller's
  job is to turn it into a 404 rather than an empty page.
  """
  def round(payload, number) do
    Enum.find(rounds(payload), &(number_of(&1) == number))
  end

  @doc """
  Every round keyed by its number, for callers that look up more than one.

  `round/2` re-filters and re-SORTS the whole list on each call, which is
  fine once and quadratic in a loop - and the masthead and the player card
  both loop over every slot. Building the index once turns that back into one
  pass.
  """
  def rounds_by_number(payload) do
    Map.new(rounds(payload), &{number_of(&1), &1})
  end

  @doc """
  A round's boards, in board order.
  """
  def boards(round), do: round |> list("boards") |> Enum.filter(&is_map/1)

  @doc """
  A round's byes.
  """
  def byes(round), do: round |> list("byes") |> Enum.filter(&is_map/1)

  @doc """
  Every player in the payload.
  """
  def players(payload), do: payload |> list("players") |> Enum.filter(&is_map/1)

  @doc """
  The players indexed by `no`, the tournament pairing number.

  `no` is the only thing that identifies a player anywhere in the document -
  boards, byes and standings rows all reference it, and no database id ever
  crosses.
  """
  def players_by_no(payload) do
    Map.new(players(payload), &{Map.get(&1, "no"), &1})
  end

  @doc """
  One player, or `nil`.
  """
  def player(payload, no), do: Enum.find(players(payload), &(Map.get(&1, "no") == no))

  @doc """
  The `standings` object, or an empty one.
  """
  def standings(payload), do: object(payload, "standings")

  @doc """
  The standings rows, in the order the arbiter sent them.

  Never sorted here. `rank` is the arbiter's answer after their tiebreaks ran,
  and re-deriving the order from `points` would quietly disagree with it the
  moment two players are level.
  """
  def standings_rows(payload), do: standings(payload) |> list("rows") |> Enum.filter(&is_map/1)

  @doc """
  The label to print beside a board - what the hall's printed sheet says.

  Falls back to the raw board number, which is what every snapshot published
  before 2026-08-29 carries and what an ordinary board's label is anyway.

  The two differ when a fixed-table player is in the round: their board is
  renumbered (1001, say) and the boards after them close the gap. Rendering
  the raw column there put the public page and the printed sheet into
  disagreement about which game is board 12.
  """
  def board_label(board) do
    case Map.get(board, "label") do
      label when is_binary(label) and label != "" -> label
      _absent -> to_string(Map.get(board, "board"))
    end
  end

  @doc """
  Whether a hand-set order has stopped describing the tournament.

  `:stale` - a result changed since the arbiter last set the order.
  `:incomplete` - a player joined afterwards and has not been placed.

  Absent means no, for the same reason as everywhere else here: a payload
  that could not tell us has not made the claim, and inventing a warning on
  an arbiter's behalf is worse than omitting one. The arbiter's own standings
  page shows both, and until 2026-08-29 neither travelled - so this site said
  "the arbiter chose this order" while their screen said "...and it may no
  longer match the real standings".
  """
  def manual_warning?(payload, kind) when kind in [:stale, :incomplete] do
    key = if kind == :stale, do: "manual_stale", else: "manual_incomplete"

    manual_order?(payload) and Map.get(standings(payload), key) == true
  end

  @doc """
  Whether the arbiter set this order by hand rather than computing it.

  Absent means no, which is both the old behaviour and the honest one: a
  payload that does not mention hand-ordering is from an app that could not
  tell us, and claiming a disclosure the arbiter never made would be worse
  than omitting one.

  The rows are rendered in the sent order either way - see `standings_rows/1`.
  This exists so the page can SAY so. The arbiter's app used to carry that
  disclosure on its own public standings page; that page was removed on
  2026-08-29, and this is where it went.
  """
  def manual_order?(payload) do
    Map.get(standings(payload), "manual_order") == true
  end

  @doc """
  How to name a round, for a tournament played as matches.

  A round-robin or swiss played in two-game matches numbers its rounds 1..2n,
  but nobody in the hall calls round 4 "round 4" - it is game 2 of match 2,
  and that is what the arbiter's own round picker says. Absent means an
  ordinary tournament, which is almost all of them.
  """
  def match_format?(payload), do: Map.get(info(payload), "match_format") == true

  @doc "Short round label: `\"3\"`, or `\"M2-1\"` for a match-format event."
  def round_label(payload, number) when is_integer(number) do
    if match_format?(payload) do
      "M#{div(number - 1, 2) + 1}-#{if rem(number, 2) == 1, do: 1, else: 2}"
    else
      to_string(number)
    end
  end

  def round_label(_payload, number), do: to_string(number)

  @doc "Full round heading: `\"Round 3\"`, or `\"Match 2, game 1\"`."
  def round_heading(payload, number) when is_integer(number) do
    if match_format?(payload) do
      "Match #{div(number - 1, 2) + 1}, game #{if rem(number, 2) == 1, do: 1, else: 2}"
    else
      "Round #{number}"
    end
  end

  def round_heading(_payload, number), do: "Round #{number}"

  @doc """
  The tournament facts a printed pairing sheet carries as a matter of course -
  deputy arbiter and time control, beside the chief arbiter the masthead
  already showed.

  Returns `[]` when the payload carries neither, which is every snapshot
  published before 2026-08-29 and most club events.
  """
  def officials(payload) do
    info = info(payload)

    [{"Deputy", string(info, "deputy")}, {"Tempo", string(info, "time_control")}]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  @doc """
  The declared tiebreaks, in the arbiter's chosen order.

  `rows[].tiebreaks` is positional against this list, which is what lets the
  renderer stay ignorant: it does not know what BH means, how many there are,
  or why this arbiter put Buchholz Cut-1 first.
  """
  def tiebreaks(payload), do: standings(payload) |> list("tiebreaks") |> Enum.filter(&is_map/1)

  @doc """
  A tiebreak's column heading: its label, or its code if the label is absent.
  """
  def tiebreak_label(tiebreak) do
    string(tiebreak, "label") || string(tiebreak, "code") || ""
  end

  @doc """
  The tiebreak value in position `index` of a standings row.

  Positional, and short rows are tolerated rather than padded: a client that
  sent fewer values than it declared columns leaves a blank cell, which is
  honest, where a zero would be a value the arbiter never computed.
  """
  def tiebreak_value(row, index) do
    row |> list("tiebreaks") |> Enum.at(index)
  end

  @doc """
  Whether the placings above were decided partly by a tie-break the arbiter
  has not published.

  Hiding a column hides the arithmetic, not its effect: two players can sit
  one above the other with every published number identical and nothing on
  the page to say why. That reads as a broken table rather than a withheld
  one, so the document carries this and the page says so.

  Absent means no, which is what publishing meant before an arbiter could
  hide tie-breaks one at a time.
  """
  def tiebreaks_withheld?(payload), do: Map.get(standings(payload), "tiebreaks_withheld") == true

  @doc """
  One player's standings row, or `nil`.
  """
  def standings_row(payload, no) do
    Enum.find(standings_rows(payload), &(Map.get(&1, "player") == no))
  end

  @doc """
  How each of `no`'s tiebreak numbers was arrived at, as
  `%{code => %{"total" => number, "parts" => [part]}}`.

  Empty when the arbiter has hidden the tiebreak columns - the working is
  withheld at build time in that case, so there is nothing here to hide - and
  empty for a tiebreak whose arithmetic is not a per-round sum, Direct
  Encounter being the one that matters.

  **Never computed here.** The contract's first rule is that the arbiter is
  the authority, and this is the sharpest case for it: Buchholz sums each
  opponent's Article 16 ADJUSTED score, not the score in their standings row,
  so adding up the numbers on this page would produce a total that disagrees
  with the one printed beside it. See `docs/snapshot-schema.md`.
  """
  def working(payload, no) do
    case standings_row(payload, no) do
      nil -> %{}
      row -> row |> object("working") |> Map.new(fn {code, w} -> {code, normalise_working(w)} end)
    end
  end

  defp normalise_working(working) when is_map(working) do
    %{
      "total" => Map.get(working, "total"),
      "parts" => working |> list("parts") |> Enum.filter(&is_map/1)
    }
  end

  defp normalise_working(_not_a_map), do: %{"total" => nil, "parts" => []}

  @doc """
  A part's kind: `"played"`, `"virtual"`, `"cut"` or `"excluded"`.

  Absent means `"played"`, which is the commonest by a wide margin and so is
  not sent - the same absent-means-the-default reading `listed` and
  `manual_order` already have.
  """
  def part_kind(part), do: string(part, "kind") || "played"

  @doc """
  Whether a part was counted towards its tiebreak's total.

  `"cut"` and `"excluded"` parts are published precisely so a reader can see
  what did NOT count and why; they must never be added back in.
  """
  def part_counted?(part), do: part_kind(part) in ["played", "virtual"]

  @doc """
  The tiebreaks with published working, in the arbiter's own column order.

  Ordered by `standings.tiebreaks` rather than by the working map's keys, so
  the explanation on a player's page reads down in the same order as the
  columns on the standings table.
  """
  def working_codes(payload, no) do
    working = working(payload, no)

    payload
    |> tiebreaks()
    |> Enum.map(&string(&1, "code"))
    |> Enum.filter(&Map.has_key?(working, &1))
  end

  @doc """
  Points the result token awards, as `{white, black}`, or `nil`.

  A token this server has never seen returns `nil` rather than a guess.
  """
  def result_points(token), do: Map.get(@result_points, token)

  @doc """
  A result token split into what to show and what it needs explaining as:
  `{base, note}`.

  The token is what travels and the renderer may present it however it likes.
  A spectator needs to see that a 1-0 was never played, and that another one
  will not move a rating, so the FIDE Art. 16 forfeit and the unrated marker
  are lifted out of the token and shown as words.

  A token from a newer client comes back verbatim and unannotated. Guessing at
  a suffix nobody here has been taught would be inventing a meaning.
  """
  def result_parts(token) when is_binary(token) do
    cond do
      not Map.has_key?(@result_points, token) -> {token, nil}
      String.ends_with?(token, "FF") -> {String.replace_suffix(token, "FF", ""), "forfeit"}
      String.ends_with?(token, "U") -> {String.replace_suffix(token, "U", ""), "unrated"}
      true -> {token, nil}
    end
  end

  # A result that is not a token is not a result. Rendered as an unreported
  # game rather than raising, because a malformed payload should cost the page
  # one cell, not the whole tournament.
  def result_parts(_absent_or_not_a_token), do: {nil, nil}

  @doc """
  One player's tournament, round by round.

  Carries an entry for every round the tournament has, published or not,
  because a card with round 4 silently missing reads as a player who sat out
  rather than as an arbiter who has not published yet.

  `:score` is the running total, and it is the only number on this site that
  did not arrive ready-made - the contract carries no per-game points on
  purpose. It stops, `nil` from there on, the moment a round's contribution is
  unknowable: an unpublished round, a board the arbiter hid, a game with no
  result yet, or a token this server cannot read. A total that stepped over a
  gap would be a number the arbiter never agreed to, and the standings page
  is where the authoritative one lives.
  """
  def card(payload, no) do
    index = players_by_no(payload)
    # Built once. `card_entry/5` used to call `round/2` per slot, and that
    # re-sorts the whole round list each time - so a card cost O(slots x
    # rounds) where the payload alone decides both.
    by_number = rounds_by_number(payload)

    payload
    |> round_slots()
    |> Enum.map_reduce({:known, 0.0}, fn number, running ->
      entry = card_entry(index, by_number, number, no)
      running = advance(running, entry.points)
      {Map.put(entry, :score, running_score(running)), running}
    end)
    |> elem(0)
  end

  defp card_entry(index, by_number, number, no) do
    entry = %{
      round: number,
      date: nil,
      kind: :unpublished,
      colour: nil,
      board: nil,
      opponent: nil,
      opponent_no: nil,
      result: nil,
      bye: nil,
      points: nil
    }

    case Map.get(by_number, number) do
      nil ->
        entry

      round ->
        entry = %{entry | date: string(round, "date")}

        cond do
          board = find_board(round, no) -> game_entry(entry, board, index, no)
          bye = find_bye(round, no) -> bye_entry(entry, bye)
          # The round is published but this player is not in it. Either they
          # were left unpaired or their board was withheld, and the payload
          # cannot tell the two apart - by design, since a hidden board is
          # absent rather than flagged. So the page says only what is true.
          true -> %{entry | kind: :no_game}
        end
    end
  end

  defp game_entry(entry, board, index, no) do
    colour = if Map.get(board, "white") == no, do: :white, else: :black
    opponent_no = if colour == :white, do: Map.get(board, "black"), else: Map.get(board, "white")
    result = Map.get(board, "result")

    points =
      case result_points(result) do
        {white, black} -> if colour == :white, do: white, else: black
        nil -> nil
      end

    %{
      entry
      | kind: :game,
        colour: colour,
        board: Map.get(board, "board"),
        opponent: Map.get(index, opponent_no),
        opponent_no: opponent_no,
        result: result,
        points: points
    }
  end

  defp bye_entry(entry, bye) do
    points = Map.get(bye, "points")

    %{
      entry
      | kind: :bye,
        bye: string(bye, "kind"),
        points: if(is_number(points), do: points)
    }
  end

  @doc """
  Each player's total as the arbiter computed it, as `%{no => points}`.

  From `standings.rows`, not derived. This is the authoritative number - the
  one the arbiter's tiebreaks ran against - and re-deriving it here would
  produce a second answer that quietly disagrees the moment a game is
  adjudicated or a forfeit is entered after the fact.

  Missing for a player with no standings row, which reads as "unknown" rather
  than zero.
  """
  def standings_points(payload) do
    for row <- standings_rows(payload),
        no = Map.get(row, "player"),
        not is_nil(no),
        into: %{},
        do: {no, Map.get(row, "points")}
  end

  @doc """
  Every player's score going INTO round `number`, as `%{no => points}`.

  What a pairing list means by "score": the points each player carried into
  the round, which is what explains why these two are on this board. The
  points they end the round with are on the standings.

  `nil` for a player whose total cannot be known, under exactly the rule
  `card/2` uses - an unpublished earlier round, a board the arbiter withheld,
  a game with no result yet, or a token this server cannot read. The two must
  agree: a player card and a pairing list disagreeing about the same number
  would be this site contradicting itself, and the contract carries no
  per-game points precisely so that nobody has to guess which is right.

  One pass over the earlier rounds rather than `card/2` per player, which
  would re-walk every round's boards once per seat on the page.
  """
  def scores_before(payload, number) do
    earlier = payload |> round_slots() |> Enum.filter(&(&1 < number))
    by_number = rounds_by_number(payload)
    start = Map.new(players(payload), &{Map.get(&1, "no"), {:known, 0.0}})

    earlier
    |> Enum.reduce(start, fn n, running ->
      contributions = round_contributions(Map.get(by_number, n))

      Map.new(running, fn {no, state} ->
        {no, advance(state, Map.get(contributions, no, :absent))}
      end)
    end)
    |> Map.new(fn {no, state} -> {no, running_score(state)} end)
  end

  # `%{no => points}` for one round, or an empty map for a round that was
  # never published - which leaves every player `:absent`, i.e. unknown,
  # which is the honest answer for a round nobody can see.
  defp round_contributions(nil), do: %{}

  defp round_contributions(round) do
    from_boards =
      for board <- boards(round),
          {seat, points} <- board_contributions(board),
          not is_nil(seat),
          into: %{},
          do: {seat, points}

    for bye <- byes(round),
        no = Map.get(bye, "player"),
        not is_nil(no),
        into: from_boards,
        do: {no, Map.get(bye, "points")}
  end

  defp board_contributions(board) do
    case result_points(Map.get(board, "result")) do
      {white, black} -> [{Map.get(board, "white"), white}, {Map.get(board, "black"), black}]
      # A board with no result yet contributes an unknown to BOTH seats,
      # rather than nothing - a game in progress is not a game worth zero.
      nil -> [{Map.get(board, "white"), :unknown}, {Map.get(board, "black"), :unknown}]
    end
  end

  defp find_board(round, no) do
    Enum.find(boards(round), &(Map.get(&1, "white") == no or Map.get(&1, "black") == no))
  end

  defp find_bye(round, no), do: Enum.find(byes(round), &(Map.get(&1, "player") == no))

  defp advance({:known, total}, points) when is_number(points), do: {:known, total + points}
  defp advance(_gap_reached_or_reaching, _points), do: :unknown

  defp running_score({:known, total}), do: total
  defp running_score(:unknown), do: nil

  defp number_of(round), do: Map.get(round, "number")

  defp object(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      object when is_map(object) -> object
      _absent_or_wrong_shape -> %{}
    end
  end

  defp object(_not_a_map, _key), do: %{}

  defp list(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      list when is_list(list) -> list
      _absent_or_wrong_shape -> []
    end
  end

  defp list(_not_a_map, _key), do: []

  defp string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _absent_or_not_a_string -> nil
    end
  end

  defp string(_not_a_map, _key), do: nil
end
