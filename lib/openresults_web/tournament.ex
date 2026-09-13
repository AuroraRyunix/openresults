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

  Two things here are words rather than data - a round's heading and the
  fallback name for a tournament that published without one - and both are
  translated. They read as data because they are built from the payload, but
  a Dutch page whose only English left is the word above the pairings is a
  page that looks broken rather than bilingual.
  """

  use Gettext, backend: OpenResultsWeb.Gettext

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
  Whether the cross-table page is offered at all.

  Two ticks, and both have to be on.

  `crosstable` is the page's own switch, and it does not exist in any
  snapshot published before the page did - so absent means shown, like every
  other key here, and an arbiter whose app has never heard of it gets the
  page.

  `pairings` is the one that is not obvious. The cross-table is the round
  pages transposed: every board, every result, every colour, all of it read
  out of the same `rounds[]` the round pages read. An arbiter who withheld
  their pairings and then found all of them on a grid one click away would
  have been handed a page that quietly undoes their own setting.
  """
  def crosstable?(payload), do: show?(payload, "pairings") and show?(payload, "crosstable")

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
    string(info, "name") || string(info, "slug") || gettext("Tournament")
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
  Where a tournament sits in its own life cycle: `:live`, `:upcoming` or
  `:finished`.

  For the front page, to group a long season's worth of events the way a
  spectator actually thinks about them rather than as one undifferentiated
  list. `today` is `Date.utc_today/0` by default and an explicit argument
  for tests - the one place in this module the wall clock enters at all.

  ## The rule, since the payload cannot state this outright

  Nothing here is sent as a single field; it is derived, in this order, from
  fields the contract already carries:

    1. **`:finished`** - the published rounds reach `rounds_count` (every
       round is in), OR `end_date` has already passed. Checked first: a
       calendar that says an event is over outranks everything else, even a
       `rounds_count` the arbiter never kept current.
    2. **`:upcoming`** - nothing has been published yet, AND `start_date` is
       either absent or still in the future.
    3. **`:live`** - everything else. The default for a tournament actually
       being played, and for one this server simply cannot place with
       confidence.

  ## The judgement calls, stated so they can be revisited

  A tournament with rounds published but no `rounds_count` (or one lower
  than what has actually been posted - a mistyped total) can never read as
  `:finished` by rule 1 alone; only a past `end_date` can close it. Silence
  reads as still running rather than as finished, because a spectator
  finding a live event mislabelled "finished" is a worse failure than the
  reverse.

  A tournament with NEITHER a published round NOR any date at all reads as
  `:upcoming` rather than `:live` - the only reading available when nothing
  the contract carries says otherwise, and the one that puts an entered but
  not-yet-started event where a spectator would expect to find it rather
  than beside events actually being played.
  """
  @spec status(map(), Date.t()) :: :live | :upcoming | :finished
  def status(payload, today \\ Date.utc_today()) do
    cond do
      finished?(payload, today) -> :finished
      upcoming?(payload, today) -> :upcoming
      true -> :live
    end
  end

  defp finished?(payload, today) do
    all_rounds_in?(payload) or past_end_date?(payload, today)
  end

  # Every round published AND its results public. A round whose results the
  # arbiter is still holding back is not over as far as this site can say,
  # however many rounds have been paired. The calendar rule beside this is
  # left alone: an event whose end date has passed is finished even with a
  # round still withheld, for the reason the doc above gives for dates
  # outranking a `rounds_count` nobody kept current.
  defp all_rounds_in?(payload) do
    all_rounds_published?(payload) and withheld_result_rounds(payload) == []
  end

  # Every round from 1 to `rounds_count`, published - not merely a published
  # round NUMBERED `rounds_count` or higher. The swiss fixture this repo
  # tests against is the reason this distinction exists at all: round 4 is
  # withheld while round 5 is already published, `rounds_count` is 5, and
  # the standings sit "after round 3" - a tournament plainly still running,
  # which "the highest published number reached the total" alone would have
  # called finished.
  defp all_rounds_published?(payload) do
    count = rounds_count(payload)
    count > 0 and MapSet.subset?(MapSet.new(1..count), MapSet.new(round_numbers(payload)))
  end

  defp past_end_date?(payload, today) do
    case parse_date(string(info(payload), "end_date")) do
      {:ok, date} -> Date.compare(date, today) == :lt
      :error -> false
    end
  end

  defp upcoming?(payload, today) do
    round_numbers(payload) == [] and not started_by?(payload, today)
  end

  # Absent means NOT known to have started - the safe reading for
  # `upcoming?`, which is the whole point of checking this rather than
  # assuming a silent tournament is already under way.
  defp started_by?(payload, today) do
    case parse_date(string(info(payload), "start_date")) do
      {:ok, date} -> Date.compare(date, today) != :gt
      :error -> false
    end
  end

  defp parse_date(nil), do: :error

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
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
  Whether a round's results are public - `rounds[].results_public`.

  `false` means the arbiter has published the round's pairings and not yet
  its results: every board arrives with `result: null` because the results
  were withheld, not because none were entered, and the pages say so once
  instead of a column of unreported games.

  **Absent means true.** An OpenPairings that predates the switch sent every
  result it had, so a round without the key is a round whose results are
  public. Anything other than a literal `false` reads the same way, for the
  same reason `registration_open` reads silence as open.
  """
  def results_public?(round) when is_map(round), do: Map.get(round, "results_public") != false
  def results_public?(_not_a_round), do: true

  @doc """
  The numbers of the published rounds whose results are withheld, in order.
  """
  def withheld_result_rounds(payload) do
    payload
    |> rounds()
    |> Enum.reject(&results_public?/1)
    |> Enum.map(&number_of/1)
    |> Enum.filter(&is_integer/1)
  end

  @doc """
  How far a round's results have come in, as `{reported, total}` over its
  boards: a board with any result token counts as reported. Counting, never
  calculating - byes are not boards and are not counted.
  """
  def results_progress(round) do
    boards = boards(round)
    {Enum.count(boards, &is_binary(Map.get(&1, "result"))), length(boards)}
  end

  @doc """
  Whether a round is live: its results are public and at least one of its
  boards has no result yet. A withheld round is never live - nothing about
  its results is public, including how many are in.
  """
  def live_round?(round) do
    {reported, total} = results_progress(round)
    results_public?(round) and reported < total
  end

  @doc """
  The live rounds, in number order - see `live_round?/1`.
  """
  def live_rounds(payload), do: payload |> rounds() |> Enum.filter(&live_round?/1)

  @doc """
  Whether any round of the tournament is live. What the page refresher polls
  faster for.
  """
  def live?(payload), do: live_rounds(payload) != []

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
  Which round the standings reflect, or `nil`.

  `0` reads as `nil` here, not as a round. OpenPairings writes
  `standings.after_round: 0` for a tournament nobody has closed a round of
  yet, and a page that printed it verbatim said "Standings after round 0" -
  a round that has never existed. Absent means the same thing for a payload
  from before this field existed, so the two collapse to one answer.
  """
  def after_round(payload) do
    case Map.get(standings(payload), "after_round") do
      round when is_integer(round) and round > 0 -> round
      _zero_or_absent -> nil
    end
  end

  @doc """
  Whether round `number` is one the STANDINGS-DERIVED pages - the
  cross-table and a player's card - may show a result for.

  Those two pages exist to agree with the standings table beside them, not
  to race ahead of it: an arbiter can publish round 6's boards while the
  standings still stop after round 5, and until they fold round 6 in, a page
  built to agree with the standings has nothing of its own to say about it.
  A round PAGE is not gated by this at all - `/round/:n` shows exactly what
  was published, live, the moment it arrives, because it never claimed to
  agree with anything but itself. See `TournamentController.round/2`.

  `false` for every round once `after_round/1` is `nil`: before the first
  standings are published there is nothing either page may show, which is
  the whole rule stated as a boundary of zero.

  This is the one place `crosstable/1` and `card/2` both read instead of
  each comparing to `after_round/1` on its own, so the boundary can only be
  wrong in one place.
  """
  @spec within_standings?(map(), integer()) :: boolean()
  def within_standings?(payload, number) when is_integer(number) do
    case after_round(payload) do
      nil -> false
      round -> number <= round
    end
  end

  @doc """
  Whether the standings page has nothing of its own to show yet: no rows, or
  no round to call them "after".

  This is the moment between a tournament being published and its first
  round closing: the arbiter's snapshot already carries every entered
  player, and there is nothing dishonest about showing them in starting
  order while the placings do not exist yet. `players(payload) != []` is
  what tells that state apart from a tournament with nothing published at
  all, which keeps its own "no standings" message - see
  `TournamentHTML.standings_table/1`.
  """
  def starting_rank?(payload) do
    (standings_rows(payload) == [] or is_nil(after_round(payload))) and players(payload) != []
  end

  @doc """
  Every player, in starting-number order - the field as entered, before a
  single result exists.

  What the standings page renders while `starting_rank?/1` holds. Not
  `crosstable/1`'s row shape: there is nothing yet to attach a cell to.
  """
  def starting_rank(payload) do
    payload
    |> players()
    |> Enum.filter(&(not is_nil(Map.get(&1, "no"))))
    |> Enum.sort_by(&Map.get(&1, "no"))
  end

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
      gettext("Match %{match}, game %{game}",
        match: div(number - 1, 2) + 1,
        game: if(rem(number, 2) == 1, do: 1, else: 2)
      )
    else
      gettext("Round %{number}", number: number)
    end
  end

  def round_heading(_payload, number), do: gettext("Round %{number}", number: number)

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
      row -> working_for_row(row)
    end
  end

  @doc """
  Same as `working/2`, for a standings ROW already in hand rather than a
  player number.

  `working/2` finds the row by searching `standings_rows/1`, which is fine
  once and quadratic across a whole table: the standings page itself walks
  every row to build the sortable, filterable table and, since this feature,
  a tiebreak cell's own expandable detail - see
  `OpenResultsWeb.TournamentHTML.standings_table/1` and `tiebreak_cell/1`.
  This is that walk's O(rows) instead of O(rows^2).
  """
  @spec working_for_row(map()) :: %{String.t() => %{String.t() => term()}}
  def working_for_row(row) when is_map(row) do
    row |> object("working") |> Map.new(fn {code, w} -> {code, normalise_working(w)} end)
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
  One player's tournament, round by round - up to the round the published
  standings reflect, and no further.

  Carries an entry for every round IN THAT RANGE, published or not, because
  a card with round 4 silently missing reads as a player who sat out rather
  than as an arbiter who has not published yet. A round beyond the range -
  published, live, with real boards and a real result - gets no entry at
  all: this is a standings-derived page, and showing its game before the
  arbiter has folded that round into the standings shown beside it is
  exactly the leak `within_standings?/2` exists to close. Empty before the
  first standings are published.

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
    |> Enum.filter(&within_standings?(payload, &1))
    # The card stops at a round whose results are withheld: the page says so
    # once, rather than a row of nothing, and a running score never steps
    # over the gap. OpenPairings never puts such a round inside the
    # standings, so this is the guard for a document that does.
    |> Enum.take_while(&results_public?(Map.get(by_number, &1)))
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

  # What a cell holds before anything is known about it. One shape for all
  # four kinds, so the template reads `cell.points` without asking first -
  # the same trick `card_entry/4` plays a few lines up.
  # The opponent is named by NUMBER and nothing else, which is the one place
  # this differs from `card/2`'s entries. A grid cell has room for a pairing
  # number and not for "Ó Súilleabháin, Séamus", and the number is what the
  # row a reader then goes looking for is keyed by.
  @empty_cell %{
    round: nil,
    kind: :none,
    colour: nil,
    opponent_no: nil,
    result: nil,
    bye: nil,
    points: nil
  }

  @doc """
  The whole tournament as one grid: a row per player, a column per PUBLISHED
  round, and in each cell the game that player had that round, read from
  their own side.

  Each row is `%{no:, player:, rank:, points:, cells: [cell]}`, and `cells`
  is positional against `round_numbers/1` - the same discipline
  `rows[].tiebreaks` uses against `standings.tiebreaks`, and for the same
  reason: the caller renders columns without knowing what a round is.

  ## Why the columns are rounds

  The other cross-table is the all-play-all square, one column per player,
  and for a round-robin of twelve it is the better document. It is not the
  one to build here. It has no cell for a bye, a forfeit against an empty
  seat or a round somebody sat out - all three simply vanish, and the row
  stops adding up to the score printed beside it. And it is quadratic: a
  450-player open is 202,500 cells, which is not a page. Rounds are what
  every result actually belongs to, and one column per round reads the same
  for a swiss, a round-robin and a keizer ladder.

  ## Why the rows are in starting-number order

  Not the standings' order, though that order is right there and this app
  renders it faithfully everywhere else. Every cell names its opponent by
  `no` and nothing else, so a reader who has just read `6w1` wants row 6 -
  and finds it, by counting, instead of hunting through a ranking. It also
  means the grid says something the standings page does not, and that it
  renders identically for a tournament whose arbiter publishes no standings
  at all.

  `rank`, `points` and `score` are the arbiter's own, lifted from the
  standings row when there is one and `nil` when there is not - a player
  entered and not yet placed, which is every player before round one.

  All three travel because a Keizer ladder's `points` are not the sum of the
  row beside them: they are the ladder's own currency, and `score` is the
  game score. Which of the two belongs at the end of a row of results is a
  question about presentation, so it is answered where the columns are
  chosen rather than here.

  ## The standings gate

  "Published" above means published AND no later than `after_round/1` - see
  `within_standings?/2`. A round can be live, with boards and results, before
  the arbiter has folded it into the standings beside this grid, and until
  they do this page has nothing of its own to say about it either: it exists
  to agree with the standings, not to race ahead of them. A round's own page
  is unaffected and keeps showing it the moment it is published. Empty
  before the first standings are published.
  """
  def crosstable(payload) do
    numbers = crosstable_rounds(payload)
    placings = Map.new(standings_rows(payload), &{Map.get(&1, "player"), &1})

    # One pass over every board and bye in the tournament, and then a lookup
    # per cell. `card/2` searches each round's boards for one player, which
    # is right for one card and quadratic for a page of them: a round's
    # boards are half its players, so the obvious loop costs players x rounds
    # x players/2 - about 1.1 million comparisons on a 450-player, 11-round
    # event, per render.
    #
    # Built from the GATED rounds only, not every published one, so a round
    # beyond `after_round/1` cannot end up in `cells` at all - not merely
    # unreachable through `numbers` below, but never read off `rounds(payload)`
    # in the first place.
    cells =
      payload
      |> rounds()
      |> Enum.filter(&(within_standings?(payload, number_of(&1)) and results_public?(&1)))
      |> Map.new(&{number_of(&1), round_cells(&1)})

    for player <- Enum.sort_by(players(payload), &Map.get(&1, "no")),
        no = Map.get(player, "no"),
        not is_nil(no) do
      placing = Map.get(placings, no, %{})

      %{
        no: no,
        player: player,
        # `placing` is `%{}` for a player the standings do not carry, and
        # `Map.get/2` on it is `nil` three times over - which is what the
        # renderer prints as an empty cell rather than as a zero.
        rank: Map.get(placing, "rank"),
        points: Map.get(placing, "points"),
        score: Map.get(placing, "score"),
        cells: Enum.map(numbers, &cell_for(cells, &1, no))
      }
    end
  end

  @doc """
  The cross-table's columns: the published rounds no later than the standings
  (`within_standings?/2`), without a round whose results are withheld - the
  page says that once rather than showing a column of nothing. The one list
  both `crosstable/1`'s cells and the page's column headings are built from.
  """
  def crosstable_rounds(payload) do
    withheld = withheld_result_rounds(payload)

    payload
    |> round_numbers()
    |> Enum.filter(&within_standings?(payload, &1))
    |> Enum.reject(&(&1 in withheld))
  end

  defp cell_for(cells, number, no) do
    cells |> Map.get(number, %{}) |> Map.get(no, %{@empty_cell | round: number})
  end

  # Every seat in one round, keyed by the player sitting in it.
  #
  # Byes first and boards over them, so a player who is somehow in both is
  # shown their game - which is what `card_entry/4` decides too. The two
  # pages must not disagree about the same round.
  defp round_cells(round) do
    number = number_of(round)

    from_byes =
      for bye <- byes(round),
          no = Map.get(bye, "player"),
          not is_nil(no),
          into: %{},
          do: {no, bye_cell(bye, number)}

    for board <- boards(round),
        {no, cell} <- board_cells(board, number),
        not is_nil(no),
        into: from_byes,
        do: {no, cell}
  end

  # The two halves of one board, each handed to the seat it belongs to.
  #
  # This is the line a cross-table gets wrong. `1-0` is a win for the seat on
  # the left of the token and a LOSS for the seat on the right, so a cell
  # showing the board's token in both players' rows tells the loser they won,
  # and it is invisible unless somebody checks both halves. The token is
  # split once, here, by the same `result_points/1` the player card and the
  # running scores already use - so the three cannot drift into different
  # answers about one game.
  defp board_cells(board, number) do
    white = Map.get(board, "white")
    black = Map.get(board, "black")
    result = Map.get(board, "result")

    # A token this server cannot read leaves BOTH seats without a score
    # rather than one of them with a guess. The renderer shows the token as
    # it arrived and says nothing about who won.
    {white_points, black_points} = result_points(result) || {nil, nil}

    [
      {white, game_cell(number, :white, black, result, white_points)},
      {black, game_cell(number, :black, white, result, black_points)}
    ]
  end

  defp game_cell(number, colour, opponent_no, result, points) do
    %{
      @empty_cell
      | round: number,
        kind: :game,
        colour: colour,
        opponent_no: opponent_no,
        result: result,
        points: points
    }
  end

  defp bye_cell(bye, number) do
    points = Map.get(bye, "points")

    %{
      @empty_cell
      | round: number,
        kind: :bye,
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

  # A round whose results are withheld contributes nothing known to anyone -
  # not even a bye's points, which do travel: a running score that moved for
  # the players with a bye and stopped for everyone else would be a partial
  # result of a round the arbiter has not published.
  defp round_contributions(%{"results_public" => false}), do: %{}

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

  ## ---------- team tournaments ----------

  @doc """
  Whether this is a team event - `tournament.team_event`. Absent means an
  individual tournament, exactly like every other flag here.
  """
  def team_event?(payload), do: Map.get(info(payload), "team_event") == true

  @doc "Every team in the payload."
  def teams(payload), do: payload |> list("teams") |> Enum.filter(&is_map/1)

  @doc "The teams indexed by `no`, the team's own pairing number."
  def teams_by_no(payload), do: Map.new(teams(payload), &{Map.get(&1, "no"), &1})

  @doc "One team, or `nil`."
  def team(payload, no), do: Enum.find(teams(payload), &(Map.get(&1, "no") == no))

  @doc "The label to print for a team: its short name when set, its name otherwise."
  def team_label(%{} = team) do
    string(team, "short_name") || string(team, "name") || ""
  end

  def team_label(_not_a_team), do: ""

  @doc """
  A team's roster, in board order, as player objects - `teams[].players`
  (a list of `no`) resolved against `players_by_no/1`. A `no` the payload
  cannot resolve is left out rather than rendered as a blank row.
  """
  def team_roster(payload, %{} = team) do
    index = players_by_no(payload)

    team
    |> Map.get("players", [])
    |> List.wrap()
    |> Enum.map(&Map.get(index, &1))
    |> Enum.reject(&is_nil/1)
  end

  def team_roster(_payload, _not_a_team), do: []

  @doc """
  The team `no` plays for, or `nil` - built from every team's roster, for the
  filter bar's "Team" control on board lines.
  """
  def player_team_no(payload, no) when not is_nil(no) do
    Enum.find_value(teams(payload), fn team ->
      if no in Map.get(team, "players", []), do: Map.get(team, "no")
    end)
  end

  def player_team_no(_payload, _no), do: nil

  @doc "A round's matches - `rounds[].matches`, present only for a team event."
  def matches(round), do: round |> list("matches") |> Enum.filter(&is_map/1)

  @doc """
  Every match `team_no` played, across every published round, oldest first -
  `%{round:, match:}`. What a team's page lists as its match history.
  """
  def team_matches(payload, team_no) do
    for round <- rounds(payload),
        match <- matches(round),
        Map.get(match, "team_a") == team_no or Map.get(match, "team_b") == team_no,
        do: %{round: number_of(round), match: match}
  end

  @doc "Which side of `match` is `team_no` - `:a`, `:b`, or `nil`."
  def match_side(match, team_no) do
    cond do
      Map.get(match, "team_a") == team_no -> :a
      Map.get(match, "team_b") == team_no -> :b
      true -> nil
    end
  end

  @doc "`team_no`'s opponent in `match`, or `nil` for a bye or an unrelated match."
  def match_opponent(match, team_no) do
    case match_side(match, team_no) do
      :a -> Map.get(match, "team_b")
      :b -> Map.get(match, "team_a")
      nil -> nil
    end
  end

  @doc """
  `team_no`'s own game points and match points in `match`, as `{gp, mp}` -
  either half `nil` while withheld or not yet decided (see
  `matches[].game_points`/`match_points` in `docs/snapshot-schema.md`).
  `{nil, nil}` for a bye or a match this team is not in.
  """
  def match_points_for(match, team_no) do
    case match_side(match, team_no) do
      :a -> {get_in(match, ["game_points", "a"]), get_in(match, ["match_points", "a"])}
      :b -> {get_in(match, ["game_points", "b"]), get_in(match, ["match_points", "b"])}
      nil -> {nil, nil}
    end
  end

  @doc """
  The team number the arbiter awarded `match` to by decision
  (`matches[].forfeit_decision`), or `nil` - for a match decided on its
  boards, for a decision withheld with the match points, and for a payload
  from a publisher older than the field. Read, never worked out: a match
  whose boards all show forfeits is not taken to be a decision.
  """
  def forfeit_decision_to(match) do
    case Map.get(match, "forfeit_decision") do
      %{"to" => no} when is_integer(no) -> no
      _ -> nil
    end
  end

  @doc "Which team has White on board 1 of `match` (see `matches[].board1_white_team`)."
  def match_white_team(match), do: Map.get(match, "board1_white_team")

  @doc "The `team_standings` object, or an empty one."
  def team_standings(payload), do: object(payload, "team_standings")

  @doc "Team standings rows, in the arbiter's own order - never re-sorted here."
  def team_standings_rows(payload),
    do: team_standings(payload) |> list("rows") |> Enum.filter(&is_map/1)

  @doc "One team's standings row, or `nil`."
  def team_standings_row(payload, no) do
    Enum.find(team_standings_rows(payload), &(Map.get(&1, "team") == no))
  end

  @doc "Which round the team standings reflect - same reading as `after_round/1`."
  def team_after_round(payload) do
    case Map.get(team_standings(payload), "after_round") do
      round when is_integer(round) and round > 0 -> round
      _zero_or_absent -> nil
    end
  end

  @doc "The declared team tie-breaks, in the arbiter's chosen order."
  def team_tiebreaks(payload),
    do: team_standings(payload) |> list("tiebreaks") |> Enum.filter(&is_map/1)

  @doc "Same as `working/2`, for `team_standings.rows[].working`."
  def team_working(payload, no) do
    case team_standings_row(payload, no) do
      nil -> %{}
      row -> working_for_row(row)
    end
  end

  @doc """
  Whether a team page has anything of its own to show yet - same reading as
  `starting_rank?/1`: no rows, or no round to call them "after".
  """
  def team_standings_pending?(payload) do
    team_standings_rows(payload) == [] or is_nil(team_after_round(payload))
  end

  @doc "Every board-prize row - `board_stats[]`, present only for a team event."
  def board_stats(payload), do: payload |> list("board_stats") |> Enum.filter(&is_map/1)

  @doc """
  `board_stats/1`, grouped by board number and sorted by it - what the board
  prizes page renders one table per.
  """
  def board_stats_by_board(payload) do
    board_stats(payload)
    |> Enum.group_by(&Map.get(&1, "board"))
    |> Enum.sort_by(fn {board, _rows} -> board end)
  end

  @doc """
  Whether the tournament offers a team-vs-team cross-table: a team event
  played as a round robin, where `matches` exists to grid. Phase 1 of a team
  Swiss still pairs its players individually (`docs/team-tournaments.md` on
  the OpenPairings side) - there is no scheduled match between two teams to
  put in a cell, only individual boards, which the ordinary cross-table
  already shows.
  """
  def team_crosstable?(payload), do: team_event?(payload) and system(payload) == "roundrobin"

  @doc """
  The team-vs-team grid for a team round robin: a row per team, a column per
  OTHER team, and in each cell the match (or matches - a double round robin
  meets twice) between them.

  Each row is `%{no:, team:, rank:, mp:, gp:, cells: %{opponent_no => [match]}}`.
  `cells` is a map rather than a positional list, unlike `crosstable/1`'s -
  there is no fixed round to be positional against here, and a double round
  robin's reversed second meeting is a second entry in the same cell rather
  than a second column.
  """
  def team_crosstable(payload) do
    placings = Map.new(team_standings_rows(payload), &{Map.get(&1, "team"), &1})

    all_matches =
      for round <- rounds(payload),
          match <- matches(round),
          do: %{round: number_of(round), match: match}

    for team <- Enum.sort_by(teams(payload), &Map.get(&1, "no")),
        no = Map.get(team, "no"),
        not is_nil(no) do
      placing = Map.get(placings, no, %{})

      cells =
        all_matches
        |> Enum.filter(&(match_opponent(&1.match, no) != nil))
        |> Enum.group_by(&match_opponent(&1.match, no))

      %{
        no: no,
        team: team,
        rank: Map.get(placing, "rank"),
        mp: Map.get(placing, "mp"),
        gp: Map.get(placing, "gp"),
        cells: cells
      }
    end
  end

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
