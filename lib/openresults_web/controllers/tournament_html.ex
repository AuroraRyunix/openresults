defmodule OpenResultsWeb.TournamentHTML do
  @moduledoc """
  The public pages' markup, and the few presentational decisions above it.

  Nothing here works out what a value should be - `OpenResultsWeb.Tournament`
  reads the payload and this module decides how a number is printed and how a
  forfeit is worded. The one rule both share: a value nobody recognises is
  shown as it arrived rather than dropped, so a newer OpenPairings publishing
  a tiebreak or a result token this server has never heard of still produces a
  page an arbiter can read.
  """

  use OpenResultsWeb, :html

  alias OpenResultsWeb.Tournament

  embed_templates "tournament_html/*"

  @doc """
  The tournament's name, its details, and the round strip.

  The strip lists every round the tournament has and not only the published
  ones. A withheld round appears as a number that is not a link, so a reader
  can see that round 4 exists and has not been posted rather than wondering
  whether they misremembered the schedule.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  attr :current, :any,
    required: true,
    doc: ":standings, :register, {:round, n} or {:player, no}"

  def masthead(assigns) do
    payload = assigns.payload

    # One index, then a lookup per slot. `Tournament.round/2` re-sorts the
    # whole round list on every call, so calling it once per slot was
    # quadratic in the payload's own `rounds_count`.
    by_number = Tournament.rounds_by_number(payload)

    slots = Enum.map(Tournament.round_slots(payload), &{&1, Map.has_key?(by_number, &1)})

    assigns =
      assigns
      |> assign(:info, Tournament.info(payload))
      |> assign(:slots, slots)
      |> assign(:show, display_rules(payload))

    ~H"""
    <header class="masthead">
      <h1>{Tournament.name(@payload)}</h1>

      <%!-- Facts a printed pairing sheet carries as a matter of course, each
            behind its own tick. Terse and only when present, because club play
            is mostly missing fields. --%>
      <p class="details">
        <span :if={@show.city && @info["city"]}>{@info["city"]}</span>
        <span :if={@show.federation && @info["federation"]}>{@info["federation"]}</span>
        <span :if={@show.dates && dates(@info)}>{dates(@info)}</span>
        <span :if={@show.arbiter && @info["arbiter"]}>Arbiter: {@info["arbiter"]}</span>
        <span :if={@show.deputy && @info["deputy"]}>Deputy: {@info["deputy"]}</span>
        <span :if={@show.time_control && @info["time_control"]}>
          Tempo: {@info["time_control"]}
        </span>
        <span :if={@show.fide_badge && @info["fide_rated"] == true}>FIDE rated</span>
      </p>

      <%!-- A navigation strip with nothing to navigate to is furniture, so it
            goes entirely when both pages behind it are off. --%>
      <nav :if={@show.standings or @show.pairings} class="rounds" aria-label="Rounds">
        <a
          :if={@show.standings}
          href={~p"/t/#{@slug}"}
          class={["chip", @current == :standings && "current"]}
        >
          Standings
        </a>
        <%= for {n, published?} <- @slots, @show.pairings do %>
          <a
            :if={published?}
            href={~p"/t/#{@slug}/round/#{n}"}
            class={["chip", @current == {:round, n} && "current"]}
          >
            {Tournament.round_label(@payload, n)}
          </a>
          <span :if={not published?} class="chip withheld" title="not published">
            {Tournament.round_label(@payload, n)}<span class="visually-hidden">, not published</span>
          </span>
        <% end %>
      </nav>

      <%!--
        The "Enter this tournament" link was here, gated on
        `registration_open`. Taken down on 2026-08-29 because the entry form
        is not finished, and a link on a public page is a promise: somebody
        follows it, fills it in, and believes they have entered.

        Only the link is gone. The form, its gate and the whole registration
        queue behind it are untouched, so this is one element to put back -
        `<p :if={Tournament.registration_open?(@payload)} class="entry">` with
        a chip linking to ~p"/t/\#{@slug}/register" - and nothing to rebuild.
      --%>
    </header>
    """
  end

  @doc """
  The tournament's dates, as one span or two.
  """
  def dates(info) do
    case {info["start_date"], info["end_date"]} do
      {nil, nil} -> nil
      {start, nil} -> start
      {nil, finish} -> finish
      {same, same} -> same
      {start, finish} -> "#{start} to #{finish}"
    end
  end

  @doc """
  The standings, in the order they arrived.

  `rows` is rendered as given. Nothing here sorts, and nothing recomputes a
  placing: `rank` is the arbiter's answer after their tiebreaks ran, and this
  page exists to agree with the printed crosstable rather than to check it.

  The tiebreak columns are driven entirely by `standings.tiebreaks` - one
  column per declared tiebreak, headed with the label the payload carries, in
  the payload's order, with `rows[].tiebreaks` read positionally against it.
  This module has never heard of Buchholz and does not need to; an arbiter who
  reorders their tiebreaks, or a client that adds a fifth, changes this page
  without changing this code.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def standings_table(assigns) do
    payload = assigns.payload

    assigns =
      assigns
      |> assign(:rows, Tournament.standings_rows(payload))
      |> assign(:tiebreaks, Tournament.tiebreaks(payload))
      |> assign(:players, Tournament.players_by_no(payload))
      # Keizer standings carry value, Keizer points and score where a swiss
      # carries points and tiebreaks. Keyed off `system`, as the contract says.
      |> assign(:keizer?, Tournament.keizer?(payload))
      |> assign(:manual_order?, Tournament.manual_order?(payload))
      |> assign(:withheld?, Tournament.tiebreaks_withheld?(payload))
      |> assign(:manual_stale?, Tournament.manual_warning?(payload, :stale))
      |> assign(:manual_incomplete?, Tournament.manual_warning?(payload, :incomplete))
      |> assign(:show, display_rules(payload))
      # Only when the tournament actually groups its players. A column of
      # dashes on every ordinary open is noise.
      |> assign(:categories?, Enum.any?(Tournament.standings_rows(payload), & &1["category"]))

    ~H"""
    <p :if={@manual_order?} class="footnote manual-order">
      The order below was set by the arbiter, not computed from the tiebreaks.
      The points and tiebreak columns are unchanged; the rank column is their
      decision.
      <span :if={@manual_incomplete?}>
        A player was added after that order was set and has not been placed in it yet.
      </span>
      <%!-- The one that matters. "The arbiter chose this order" and "the
            arbiter chose this order and it is now out of date" are different
            statements, and only the first was travelling. --%>
      <strong :if={@manual_stale?}>
        A result has changed since the order was last set, so it may no longer match the
        real standings.
      </strong>
    </p>

    <%!-- Said where the ordering is, not on a player's card, because the
          question it answers is about the table: why is that person above
          me when every number I can see is the same? --%>
    <p :if={@withheld? and @rows != []} class="footnote">
      The order also uses tie-breaks this tournament does not publish, so two
      players can appear one above the other with every column here identical.
    </p>

    <p :if={@rows == []} class="empty">
      No standings have been published for this tournament yet.
    </p>

    <div :if={@rows != []} class="scroller">
      <table class="standings">
        <thead>
          <tr>
            <th class="num" scope="col">#</th>
            <th scope="col">Player</th>
            <th :if={@show.rating} class="num" scope="col">Rating</th>
            <th :if={@categories? and @show.category} scope="col">Cat</th>
            <%= if @keizer? do %>
              <th class="num" scope="col">Value</th>
              <th class="num" scope="col">Keizer points</th>
              <th class="num" scope="col">Score</th>
            <% else %>
              <th class="num" scope="col">Points</th>
              <%!-- The placings are unaffected by hiding these. The arbiter
                    is hiding the arithmetic, not the result - the order is
                    still exactly the one they computed. --%>
              <th :for={tiebreak <- @tiebreaks} :if={@show.tiebreaks} class="num" scope="col">
                {Tournament.tiebreak_label(tiebreak)}
              </th>
            <% end %>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td class="num rank">{row["rank"]}</td>
            <td>
              <.player_link
                slug={@slug}
                no={row["player"]}
                player={@players[row["player"]]}
                show={@show}
                cards?={@show.player_cards}
                detail
              />
            </td>
            <td :if={@show.rating} class="num">{dash(@players[row["player"]]["rating"])}</td>
            <td :if={@categories? and @show.category}>{dash(row["category"])}</td>
            <%= if @keizer? do %>
              <td class="num">{number(row["value"])}</td>
              <td class="num strong">{number(row["points"])}</td>
              <td class="num">{number(row["score"])}</td>
            <% else %>
              <td class="num strong">{number(row["points"])}</td>
              <td
                :for={{_tiebreak, at} <- Enum.with_index(@tiebreaks)}
                :if={@show.tiebreaks}
                class="num"
              >
                {number(Tournament.tiebreak_value(row, at))}
              </td>
            <% end %>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  One round's boards.

  Only the boards that were published are here, because a board the arbiter
  hid was withheld when the document was built. There is no filtering to
  forget and nothing on the server to leak.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true

  def pairings_table(assigns) do
    show = display_rules(assigns.payload)

    assigns =
      assigns
      |> assign(:boards, Tournament.boards(assigns.round))
      |> assign(:show, show)
      # The points each player carried INTO this round, which is what a
      # pairing list means by score and what explains why these two are on
      # this board. Their points after it are on the standings.
      |> assign(:scores, Tournament.scores_before(assigns.payload, assigns.round["number"]))

    ~H"""
    <p :if={@boards == []} class="empty">No boards were published for this round.</p>

    <div :if={@boards != []} class="scroller">
      <table class="pairings">
        <thead>
          <tr>
            <th class="num" scope="col">Bd</th>
            <th :if={@show.rating} class="num" scope="col">Elo</th>
            <th
              :if={@show.pairing_scores}
              class="num"
              scope="col"
              title="Points going into this round"
            >
              Pts
            </th>
            <th scope="col">White</th>
            <th class="num" scope="col">Result</th>
            <th scope="col">Black</th>
            <th
              :if={@show.pairing_scores}
              class="num"
              scope="col"
              title="Points going into this round"
            >
              Pts
            </th>
            <th :if={@show.rating} class="num" scope="col">Elo</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={board <- @boards}>
            <td class="num">{Tournament.board_label(board)}</td>
            <td :if={@show.rating} class="num">{dash(@players[board["white"]]["rating"])}</td>
            <td :if={@show.pairing_scores} class="num">
              <.score points={@scores[board["white"]]} />
            </td>
            <td>
              <.player_link
                slug={@slug}
                no={board["white"]}
                player={@players[board["white"]]}
                show={@show}
                cards?={@show.player_cards}
                detail
              />
            </td>
            <td class="num"><.result token={board["result"]} /></td>
            <td>
              <.player_link
                slug={@slug}
                no={board["black"]}
                player={@players[board["black"]]}
                show={@show}
                cards?={@show.player_cards}
                detail
              />
            </td>
            <td :if={@show.pairing_scores} class="num">
              <.score points={@scores[board["black"]]} />
            </td>
            <td :if={@show.rating} class="num">{dash(@players[board["black"]]["rating"])}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  A running score, or a marker where it cannot be known.

  A blank would read as zero. `Tournament.scores_before/2` returns `nil` the
  moment an earlier round is unpublished, withheld or unfinished, and saying
  so is the point - a total that stepped over a gap would be a number the
  arbiter never agreed to.
  """
  attr :points, :any, default: nil

  def score(assigns) do
    ~H"""
    <span :if={is_nil(@points)} class="unreported" title="an earlier round is not public">-</span>
    <span :if={not is_nil(@points)}>{number(@points)}</span>
    """
  end

  @doc """
  A round's byes.

  The kind and the value both come from the payload. The value is
  configurable, so a half-point bye worth something other than a half point is
  the arbiter's decision to state and not this app's to assume.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true

  def byes_table(assigns) do
    assigns =
      assigns
      |> assign(:byes, Tournament.byes(assigns.round))
      |> assign(:show, display_rules(assigns.payload))

    ~H"""
    <div :if={@byes != []} class="scroller">
      <table class="byes">
        <thead>
          <tr>
            <th scope="col">Player</th>
            <th :if={@show.rating} class="num" scope="col">Elo</th>
            <th scope="col">Bye</th>
            <th class="num" scope="col">Points</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={bye <- @byes}>
            <%!-- `detail` and an Elo column, matching the boards table above.
                  Without them a player sitting out lost their title and rating
                  from a page that shows both for everybody who is playing. --%>
            <td>
              <.player_link
                slug={@slug}
                no={bye["player"]}
                player={@players[bye["player"]]}
                show={@show}
                cards?={@show.player_cards}
                detail
              />
            </td>
            <td :if={@show.rating} class="num">{dash(@players[bye["player"]]["rating"])}</td>
            <td>{bye_kind(bye["kind"])}</td>
            <td class="num">{number(bye["points"])}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  One player's game in each round.

  Every round gets a row, including the ones the arbiter has not published, so
  the gaps are visible instead of being closed up.
  """
  attr :slug, :string, required: true
  attr :card, :list, required: true
  attr :payload, :map, required: true

  def card_table(assigns) do
    show = display_rules(assigns.payload)

    assigns =
      assigns
      |> assign(:show, show)
      # Each opponent's own total, so a reader can see the strength of the
      # field somebody actually played - the same column the arbiter's own
      # Players Card carries, and the reason a 4/5 against the top boards
      # reads differently from 4/5 against the bottom.
      |> assign(:totals, Tournament.standings_points(assigns.payload))
      # `:game` rows span the same columns as the placeholders below them, so
      # the two have to agree. Counted rather than written out, because they
      # move with the arbiter's ticks.
      |> assign(:game_span, 3 + count_if([show.federation, show.title, show.rating]))

    ~H"""
    <div class="scroller">
      <table class="card">
        <thead>
          <tr>
            <th class="num" scope="col">Rd</th>
            <th scope="col">Colour</th>
            <th class="num" scope="col" title="Opponent's pairing number">No</th>
            <th :if={@show.federation} scope="col">Nat</th>
            <th :if={@show.title} scope="col">Tit</th>
            <th scope="col">Opponent</th>
            <th :if={@show.rating} class="num" scope="col">Elo</th>
            <th class="num" scope="col" title="Opponent's total">Pts</th>
            <th class="num" scope="col">Result</th>
            <th class="num" scope="col">Score</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={entry <- @card} class={entry.kind == :unpublished && "withheld"}>
            <td class="num">{entry.round}</td>
            <%= case entry.kind do %>
              <% :game -> %>
                <td>{if(entry.colour == :white, do: "White", else: "Black")}</td>
                <td class="num">{entry.opponent_no}</td>
                <td :if={@show.federation}>{dash(entry.opponent && entry.opponent["federation"])}</td>
                <td :if={@show.title}>{dash(entry.opponent && entry.opponent["title"])}</td>
                <td>
                  <.player_link
                    slug={@slug}
                    no={entry.opponent_no}
                    player={entry.opponent}
                    show={@show}
                    cards?={@show.player_cards}
                  />
                </td>
                <td :if={@show.rating} class="num">
                  {dash(entry.opponent && entry.opponent["rating"])}
                </td>
                <td class="num"><.score points={@totals[entry.opponent_no]} /></td>
                <td class="num"><.result token={entry.result} /></td>
              <% :bye -> %>
                <td></td>
                <td colspan={@game_span} class="quiet">{bye_kind(entry.bye)}</td>
                <td class="num">{number(entry.points)}</td>
              <% :unpublished -> %>
                <td colspan={@game_span + 2} class="quiet">not published</td>
              <% _no_game -> %>
                <td colspan={@game_span + 2} class="quiet">no game published for this round</td>
            <% end %>
            <td class="num strong">{number(entry.score)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp count_if(flags), do: Enum.count(flags, & &1)

  # A blank table cell reads as "nobody has typed this in"; a dash reads as
  # "there is none". They are different claims, and for a rating the second is
  # the true one - an unrated player is not a player whose rating is pending.
  defp dash(nil), do: "-"
  defp dash(""), do: "-"
  defp dash(value), do: value

  # The arbiter's display rules as a plain map with atom keys, resolved once
  # per table. Every key defaults to shown - see `Tournament.show?/2` for why
  # that direction is the safe one.
  defp display_rules(payload) do
    Map.new(
      ~w(standings pairings player_cards byes rating title federation club category
         city dates arbiter deputy time_control fide_badge tiebreaks pairing_scores),
      &{String.to_atom(&1), Tournament.show?(payload, &1)}
    )
  end

  @doc """
  A player, linked to their card.

  Falls back to the bare pairing number when the payload references a player
  it does not list. That should not happen, but a page that renders a
  tournament minus one board beats a page that renders nothing.
  """
  attr :slug, :string, required: true
  attr :no, :any, required: true
  attr :player, :map, default: nil

  attr :detail, :boolean,
    default: false,
    doc: """
    Show the title alongside the name. Not the rating: every table that wants
    one has a column for it, and rendering it here as well printed it twice
    on the standings - which it did before the pairings gained a column, and
    which adding one to the pairings would have repeated.
    """

  attr :show, :map,
    default: %{},
    doc: "the arbiter's display rules; missing keys mean shown, as everywhere else"

  attr :cards?, :boolean, default: true, doc: "false renders the name without a link"

  def player_link(assigns) do
    ~H"""
    <a
      :if={@no && @cards?}
      href={~p"/t/#{@slug}/player/#{@no}"}
      class="player"
      data-player={@no}
    >
      <span :if={@detail && shown?(@show, :title) && @player && @player["title"]} class="title">
        {@player["title"]}
      </span>
      <span class="name">{(@player && @player["name"]) || "Player #{@no}"}</span>
    </a>
    <span :if={@no && not @cards?} class="player">
      <span :if={@detail && shown?(@show, :title) && @player && @player["title"]} class="title">
        {@player["title"]}
      </span>
      <span class="name">{(@player && @player["name"]) || "Player #{@no}"}</span>
    </span>
    <span :if={is_nil(@no)} class="player">-</span>
    """
  end

  @doc """
  Why this player is where they are: their placing, their score, and what
  each tiebreak was made of.

  This is the block the overlay card shows. It is deliberately the SUMMARY
  and not the whole page - before the working existed, right-clicking a name
  fetched the player page and put its one section in a dialog, so the two
  gestures produced identical content and the overlay's only value was not
  losing your place in the standings. Left-click now leads somewhere with
  more in it: the round-by-round table, the chart, and every contribution
  named.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :no, :integer, required: true

  def placing(assigns) do
    payload = assigns.payload
    row = Tournament.standings_row(payload, assigns.no)

    assigns =
      assigns
      |> assign(:row, row)
      |> assign(:working, Tournament.working(payload, assigns.no))
      |> assign(:codes, Tournament.working_codes(payload, assigns.no))
      |> assign(:labels, tiebreak_labels(payload))
      |> assign(:show, display_rules(payload))

    ~H"""
    <p :if={@row} class="placing">
      <span class="placing-rank">{@row["rank"]}</span>
      <span class="placing-of">
        of {length(Tournament.standings_rows(@payload))}, on {number(@row["points"])}
      </span>
    </p>

    <table :if={@codes != [] and @show.tiebreaks} class="tiebreak-summary">
      <tbody>
        <tr :for={code <- @codes}>
          <th scope="row">{@labels[code]}</th>
          <td class="num strong">{number(@working[code]["total"])}</td>
          <td class="quiet">{composition(@working[code]["parts"])}</td>
        </tr>
      </tbody>
    </table>

    <p :if={@codes == [] and @show.tiebreaks} class="footnote">
      This tournament publishes no breakdown of its tie-breaks.
    </p>

    <%!-- The placing above is a claim, so the same caveat belongs here: what
          is listed may not be everything that put them there. --%>
    <p :if={Tournament.tiebreaks_withheld?(@payload)} class="footnote">
      The order also uses tie-breaks this tournament does not publish.
    </p>
    """
  end

  # One line saying what a tiebreak is made of, without repeating the table
  # underneath it on the full page. Says only what is true of THIS list: a
  # tiebreak with nothing discarded says nothing about discarding.
  defp composition(parts) do
    counted = Enum.count(parts, &Tournament.part_counted?/1)
    cut = Enum.count(parts, &(Tournament.part_kind(&1) == "cut"))
    excluded = Enum.count(parts, &(Tournament.part_kind(&1) == "excluded"))
    virtual = Enum.count(parts, &(Tournament.part_kind(&1) == "virtual"))

    [
      "from #{counted} #{pluralise(counted, "round", "rounds")}",
      virtual > 0 && "#{virtual} unplayed",
      cut > 0 && "#{cut} discarded",
      excluded > 0 && "#{excluded} not counted"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp pluralise(1, one, _many), do: one
  defp pluralise(_n, _one, many), do: many

  @doc """
  Every tiebreak's working in full: one row per round, with the opponent it
  came from and what it was worth.

  The values are the arbiter's own, sent with the document. Nothing on this
  page adds them up to check, and nothing recomputes them - see
  `OpenResultsWeb.Tournament.working/2` for why that would be worse than
  useless here.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :no, :integer, required: true

  def working_tables(assigns) do
    payload = assigns.payload

    assigns =
      assigns
      |> assign(:working, Tournament.working(payload, assigns.no))
      |> assign(:codes, Tournament.working_codes(payload, assigns.no))
      |> assign(:labels, tiebreak_labels(payload))
      |> assign(:players, Tournament.players_by_no(payload))
      |> assign(:show, display_rules(payload))

    ~H"""
    <section :if={@codes != [] and @show.tiebreaks} class="working">
      <h3>Where the tie-breaks come from</h3>

      <div :for={code <- @codes} class="working-block">
        <h4>
          {@labels[code]}
          <span class="num strong">{number(@working[code]["total"])}</span>
        </h4>

        <div class="scroller">
          <table class="working-table">
            <thead>
              <tr>
                <th class="num" scope="col">Rd</th>
                <th scope="col">From</th>
                <th class="num" scope="col">Value</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={part <- @working[code]["parts"]}
                class={not Tournament.part_counted?(part) && "withheld"}
              >
                <td class="num">{part["round"]}</td>
                <td>
                  <.part_source
                    part={part}
                    slug={@slug}
                    player={@players[part["opponent"]]}
                    show={@show}
                  />
                </td>
                <td class="num">{number(part["value"])}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <p class="footnote">
        These are the arbiter's numbers, published with the results - this page
        does not calculate them. An unplayed round contributes a notional
        opponent under FIDE Article 16 rather than a real one, which is why
        some rows name nobody.
      </p>
    </section>
    """
  end

  # What a contribution came from: an opponent, a rule, or nobody.
  attr :part, :map, required: true
  attr :slug, :string, required: true
  attr :player, :map, default: nil
  attr :show, :map, default: %{}

  def part_source(assigns) do
    ~H"""
    <.player_link
      :if={@part["opponent"]}
      slug={@slug}
      no={@part["opponent"]}
      player={@player}
      show={@show}
      cards?={Map.get(@show, :player_cards, true)}
    />
    <span :if={is_nil(@part["opponent"])} class="quiet">
      {source_label(@part)}
    </span>
    <span :if={Tournament.part_kind(@part) == "cut"} class="tag">discarded</span>
    <span :if={Tournament.part_kind(@part) == "excluded" and @part["opponent"]} class="tag">
      not counted
    </span>
    """
  end

  # A part with no opponent to name is an unplayed round - Article 16's
  # notional opponent - and stays one after a cut modifier discards it. `kind`
  # holds one value, so marking it `"cut"` overwrites `"virtual"`; the absent
  # opponent is what survives, and it is enough. The "discarded" tag beside
  # this says the rest.
  defp source_label(part) do
    case Tournament.part_kind(part) do
      "excluded" -> "not counted"
      _virtual_or_cut -> "unplayed round"
    end
  end

  @doc """
  One picture of a player's tournament: what each round contributed to a
  tie-break, and how their own score climbed.

  Both series are in POINTS, which is the only reason they can share an axis.
  A dual-scale chart that put a running total and a per-round contribution on
  different axes would let the two cross wherever the scaling happened to put
  them, and the crossing would mean nothing.

  The bars are the tie-break's own published contributions - the strength of
  the field this player actually faced, which is what a Buchholz IS. A bar
  the arbiter's rules did not count (discarded by a cut, or below Koya's
  threshold) is drawn in the withheld colour rather than left out, because
  "that round did not help you" is the interesting part.

  Inline SVG, no library: this site ships one stylesheet and one script, and
  a chart is not a reason to change that.
  """
  attr :payload, :map, required: true
  attr :card, :list, required: true
  attr :no, :integer, required: true

  def score_chart(assigns) do
    payload = assigns.payload
    code = assigns.payload |> Tournament.working_codes(assigns.no) |> List.first()
    working = Tournament.working(payload, assigns.no)

    bars =
      case code do
        nil -> %{}
        code -> Map.new(working[code]["parts"], &{Map.get(&1, "round"), &1})
      end

    points =
      for entry <- assigns.card,
          is_number(entry.score),
          do: {entry.round, entry.score}

    max =
      [
        Enum.map(points, &elem(&1, 1)),
        bars |> Map.values() |> Enum.map(&Map.get(&1, "value", 0)) |> Enum.filter(&is_number/1)
      ]
      |> List.flatten()
      |> Enum.max(fn -> 0 end)

    assigns =
      assigns
      |> assign(:code, code)
      |> assign(:label, code && tiebreak_labels(payload)[code])
      |> assign(:bars, bars)
      |> assign(:points, points)
      |> assign(:rounds, Enum.map(assigns.card, & &1.round))
      |> assign(:max, max)

    ~H"""
    <figure :if={@rounds != [] and @max > 0} class="chart">
      <svg viewBox="0 0 640 190" class="chart-svg" role="img">
        <title>
          {chart_title(@label)}
        </title>

        <%!-- Gridlines at whole points, labelled. Two decimals would be
              noise on an axis whose whole job is "roughly how big". --%>
        <g class="chart-grid">
          <g :for={value <- gridlines(@max)}>
            <line x1="30" x2="630" y1={y(value, @max)} y2={y(value, @max)} />
            <text x="24" y={y(value, @max) + 4} text-anchor="end">{trunc(value)}</text>
          </g>
        </g>

        <g :for={{round, index} <- Enum.with_index(@rounds)}>
          <% part = @bars[round] %>
          <rect
            :if={part && is_number(part["value"]) && part["value"] > 0}
            x={bar_x(index, @rounds) - bar_width(@rounds) / 2}
            y={y(part["value"], @max)}
            width={bar_width(@rounds)}
            height={164 - y(part["value"], @max)}
            class={
              if(Tournament.part_counted?(part), do: "chart-bar", else: "chart-bar chart-bar-out")
            }
          />
          <text x={bar_x(index, @rounds)} y="182" text-anchor="middle" class="chart-round">
            {round}
          </text>
        </g>

        <%!-- The score line stops where the running total does: at the first
              round whose contribution is not public. A line drawn across that
              gap would be a number the arbiter never published. --%>
        <polyline
          :if={length(@points) > 1}
          class="chart-line"
          points={line_points(@points, @rounds, @max)}
        />
        <circle
          :for={{round, score} <- @points}
          cx={bar_x(Enum.find_index(@rounds, &(&1 == round)), @rounds)}
          cy={y(score, @max)}
          r="3"
          class="chart-dot"
        />
      </svg>

      <figcaption>
        <span class="chart-key chart-key-line"></span>
        running score
        <span :if={@label}>
          <span class="chart-key chart-key-bar"></span> what each round gave to {@label}
        </span>
      </figcaption>
    </figure>
    """
  end

  defp chart_title(nil), do: "The player's running score by round."

  defp chart_title(label),
    do: "The player's running score by round, and each round's contribution to #{label}."

  # A FIXED 640x190 viewBox, with the rounds distributed across it rather
  # than a width that grows per round. The first version sized the box by
  # round count, so a five-round event produced a nearly square viewBox that
  # `width: 100%; height: auto` then scaled into a chart taller than the
  # screen. The aspect ratio has to be decided here, not by the data.
  @chart_left 34
  @chart_right 630

  defp chart_slot(rounds), do: (@chart_right - @chart_left) / max(length(rounds), 1)
  defp bar_x(index, rounds), do: @chart_left + chart_slot(rounds) * (index + 0.5)
  defp bar_width(rounds), do: min(28.0, chart_slot(rounds) * 0.55)

  # 26px of bottom gutter for the round numbers, 12px of headroom on top.
  defp y(_value, max) when max <= 0, do: 164
  defp y(value, max), do: 164 - value / max * 138

  defp gridlines(max) do
    step = if max > 8, do: 2, else: 1
    Stream.iterate(0, &(&1 + step)) |> Enum.take_while(&(&1 <= max)) |> Enum.map(&(&1 / 1))
  end

  defp line_points(points, rounds, max) do
    Enum.map_join(points, " ", fn {round, score} ->
      "#{bar_x(Enum.find_index(rounds, &(&1 == round)), rounds)},#{y(score, max)}"
    end)
  end

  defp tiebreak_labels(payload) do
    payload
    |> Tournament.tiebreaks()
    |> Map.new(fn tb -> {Map.get(tb, "code"), Tournament.tiebreak_label(tb)} end)
  end

  # Missing means shown, matching `Tournament.show?/2`. Callers build this map
  # once per table rather than asking the payload per cell.
  defp shown?(show, key), do: Map.get(show, key, true)

  @doc """
  A result token, with its forfeit or unrated marker spelled out.

  A game with no result yet is a hyphen rather than a blank, because a blank
  cell in a pairing list reads as a board nobody has typed in, which is a
  different thing from a game still in progress.
  """
  attr :token, :any, required: true

  def result(assigns) do
    {base, note} = Tournament.result_parts(assigns.token)
    assigns = assigns |> assign(:base, base) |> assign(:note, note)

    ~H"""
    <span class="result">
      <span :if={@base} class="token">{@base}</span>
      <span :if={is_nil(@base)} class="unreported" title="not yet reported">-</span>
      <span :if={@note} class="note">{@note}</span>
    </span>
    """
  end

  @doc """
  A number as a scoreboard prints it: `2.5`, `17`, `22.25`.

  Trailing `.0` goes, because JSON has one number type and an arbiter writing
  17 Keizer points did not mean 17.0. Anything that is not a number comes back
  as `nil` and leaves the cell empty - a tiebreak value of the wrong shape is
  worth one blank cell, not a crashed page.
  """
  def number(value) when is_integer(value), do: Integer.to_string(value)

  def number(value) when is_float(value) do
    if trunc(value) == value, do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  def number(value) when is_binary(value), do: value
  def number(_not_a_number), do: nil

  @doc """
  A bye's kind, as an arbiter would say it out loud.

  Unrecognised kinds pass through: the contract lists five, and a sixth from a
  newer client is still something to show.
  """
  def bye_kind("pairing-allocated"), do: "pairing-allocated bye"
  def bye_kind("half-point"), do: "half-point bye"
  def bye_kind("zero-point"), do: "zero-point bye"
  def bye_kind("full-point"), do: "full-point bye"
  def bye_kind("absent"), do: "absent"
  def bye_kind(kind) when is_binary(kind), do: kind
  def bye_kind(_absent), do: "bye"
end
