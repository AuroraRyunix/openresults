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
