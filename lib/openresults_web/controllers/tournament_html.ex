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
    doc: ":standings, :crosstable, :register, {:round, n} or {:player, no}"

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
        <span :if={@show.arbiter && @info["arbiter"]}>
          {gettext("Arbiter: %{name}", name: @info["arbiter"])}
        </span>
        <span :if={@show.deputy && @info["deputy"]}>
          {gettext("Deputy: %{name}", name: @info["deputy"])}
        </span>
        <span :if={@show.time_control && @info["time_control"]}>
          {gettext("Tempo: %{time_control}", time_control: @info["time_control"])}
        </span>
        <span :if={@show.fide_badge && @info["fide_rated"] == true}>{gettext("FIDE rated")}</span>
      </p>

      <%!-- A navigation strip with nothing to navigate to is furniture, so it
            goes entirely when both pages behind it are off. --%>
      <nav :if={@show.standings or @show.pairings} class="rounds" aria-label={gettext("Rounds")}>
        <a
          :if={@show.standings}
          href={~p"/t/#{@slug}"}
          class={["chip", @current == :standings && "current"]}
        >
          {gettext("Standings")}
        </a>
        <%!-- The grid, beside the pages it is made of. Behind the pairings
              tick as well as its own, because it IS the pairings - see
              `Tournament.crosstable?/1`. --%>
        <a
          :if={@show.pairings and @show.crosstable}
          href={~p"/t/#{@slug}/crosstable"}
          class={["chip", @current == :crosstable && "current"]}
        >
          {gettext("Cross-table")}
        </a>
        <%= for {n, published?} <- @slots, @show.pairings do %>
          <a
            :if={published?}
            href={~p"/t/#{@slug}/round/#{n}"}
            class={["chip", @current == {:round, n} && "current"]}
          >
            {Tournament.round_label(@payload, n)}
          </a>
          <span :if={not published?} class="chip withheld" title={gettext("not published")}>
            {Tournament.round_label(@payload, n)}<span class="visually-hidden">{gettext(
              ", not published"
            )}</span>
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
      {start, finish} -> gettext("%{start} to %{finish}", start: start, finish: finish)
    end
  end

  @doc """
  An anchor as one gettext binding, for a sentence with a link inside it.

  A translator moving the link to the other end of a Dutch sentence must not
  have to move a tag with it, and chopping the sentence into fragments around
  the tag would leave them ordering words they cannot see together. So the
  sentence stays whole in the catalogue and the anchor arrives as `%{...}`.

  The result is raw HTML and its caller has to `raw/1` it, which is the whole
  reason this escapes both halves itself. Never hand it anything from a
  payload: it is for this app's own routes and its own strings.
  """
  def anchor(href, text) do
    ~s(<a href="#{escaped(href)}">#{escaped(text)}</a>)
  end

  @doc """
  One value, escaped and back to a string, for interpolating into a gettext
  binding that will be rendered raw.
  """
  def escaped(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

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
      {gettext(
        "The order below was set by the arbiter, not computed from the tiebreaks. The points and tiebreak columns are unchanged; the rank column is their decision."
      )}
      <span :if={@manual_incomplete?}>
        {gettext("A player was added after that order was set and has not been placed in it yet.")}
      </span>
      <%!-- The one that matters. "The arbiter chose this order" and "the
            arbiter chose this order and it is now out of date" are different
            statements, and only the first was travelling. --%>
      <strong :if={@manual_stale?}>
        {gettext(
          "A result has changed since the order was last set, so it may no longer match the real standings."
        )}
      </strong>
    </p>

    <%!-- Said where the ordering is, not on a player's card, because the
          question it answers is about the table: why is that person above
          me when every number I can see is the same? --%>
    <p :if={@withheld? and @rows != []} class="footnote">
      {gettext(
        "The order also uses tie-breaks this tournament does not publish, so two players can appear one above the other with every column here identical."
      )}
    </p>

    <p :if={@rows == []} class="empty">
      {gettext("No standings have been published for this tournament yet.")}
    </p>

    <div :if={@rows != []} class="scroller">
      <table class="standings">
        <thead>
          <tr>
            <th class="num" scope="col">{gettext("#")}</th>
            <th scope="col">{gettext("Player")}</th>
            <th :if={@show.rating} class="num" scope="col">{gettext("Rating")}</th>
            <th :if={@categories? and @show.category} scope="col">{gettext("Cat")}</th>
            <%= if @keizer? do %>
              <th class="num" scope="col">{gettext("Value")}</th>
              <th class="num" scope="col">{gettext("Keizer points")}</th>
              <th class="num" scope="col">{gettext("Score")}</th>
            <% else %>
              <th class="num" scope="col">{gettext("Points")}</th>
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
  The cross-table: a row per player, a column per published round.

  What every other results site has and this one did not. It answers the
  question the standings and the round pages between them make a reader
  assemble by hand - who did this player actually play, and what happened -
  and it is the first thing an arbiter looks for.

  ## The columns

  Only PUBLISHED rounds, so an arbiter who has posted 1, 2, 3 and 5 gets four
  columns and no gap where 4 would be. That is the opposite of the round
  strip in the masthead, which shows the gap on purpose: a strip is a list of
  what exists, and this is a table of results, where an empty column would
  read as a round nobody turned up to.

  Each heading links to that round's own page, which is where the boards,
  the ratings and the scores going in are.

  ## The two columns that stay put

  The pairing number and the name are pinned to the left edge while the
  rounds scroll under them. A 450-player, eleven-round grid is wider than
  any screen, and a reader who has scrolled to round 9 without them is
  looking at a wall of numbers belonging to nobody. Everything else about
  the width is `.scroller`'s job - the table scrolls inside its own box and
  the page body never moves sideways.

  ## What a cell is not

  Not the board's result token. `1-0` is a win for one seat and a loss for
  the other, so each cell carries the score of the player whose ROW it is -
  see `OpenResultsWeb.Tournament.crosstable/1`, where the split happens.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def crosstable_table(assigns) do
    payload = assigns.payload
    rows = Tournament.crosstable(payload)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:rounds, Tournament.round_numbers(payload))
      |> assign(:show, display_rules(payload))
      # A Keizer ladder's "points" are the ladder's own currency and not the
      # sum of the row they would sit beside: player 1 of the fixture has two
      # wins and 17 points. The game score is the number that belongs at the
      # end of a row of results, and Keizer standings carry it separately.
      |> assign(:keizer?, Tournament.keizer?(payload))
      # Only when the arbiter has actually published placings. Two columns of
      # blanks on a tournament that has not ranked anybody yet is noise, and
      # this page is deliberately readable without a standings block at all.
      |> assign(:placings?, Enum.any?(rows, &(&1.rank || &1.points || &1.score)))

    ~H"""
    <p :if={@rows == [] or @rounds == []} class="empty">
      {gettext("No rounds have been published for this tournament yet.")}
    </p>

    <div :if={@rows != [] and @rounds != []} class="scroller">
      <table class="crosstable">
        <thead>
          <tr>
            <th class="num xt-no" scope="col" title={gettext("Starting number")}>{gettext("No")}</th>
            <th class="xt-name" scope="col">{gettext("Player")}</th>
            <th :if={@show.rating} class="num" scope="col">{gettext("Elo")}</th>
            <th :for={n <- @rounds} class="xt-round" scope="col">
              <a href={~p"/t/#{@slug}/round/#{n}"} title={Tournament.round_heading(@payload, n)}>
                {Tournament.round_label(@payload, n)}
              </a>
            </th>
            <th :if={@show.standings and @placings?} class="num" scope="col">
              {if(@keizer?, do: gettext("Score"), else: gettext("Points"))}
            </th>
            <th :if={@show.standings and @placings?} class="num" scope="col">{gettext("Rank")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td class="num xt-no">{row.no}</td>
            <td class="xt-name">
              <.player_link
                slug={@slug}
                no={row.no}
                player={row.player}
                show={@show}
                cards?={@show.player_cards}
                detail
              />
            </td>
            <td :if={@show.rating} class="num">{dash(row.player["rating"])}</td>
            <.crosstable_cell :for={cell <- row.cells} cell={cell} slug={@slug} show={@show} />
            <td :if={@show.standings and @placings?} class="num strong">
              {number(if(@keizer?, do: row.score, else: row.points))}
            </td>
            <td :if={@show.standings and @placings?} class="num rank">{row.rank}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <%!-- The key. A cross-table is notation before it is a table, and a
          reader who has not seen one before is owed the sentence that turns
          `6w1` into words - in their own language, which is why the two
          letters are spelled out here rather than only sitting in a tooltip
          nobody on a phone can open. --%>
    <p :if={@rows != [] and @rounds != []} class="footnote">
      {gettext(
        "Each cell is one round: the opponent's pairing number, the colour this player had - w for White, b for Black - and the score from this player's own side."
      )}
      {gettext(
        "A bye or a forfeit is named under the score, because neither is an ordinary result. An empty cell is a round this player is not listed in."
      )}
    </p>
    """
  end

  # One player's round: who they played, which colour they had and what they
  # scored - or the bye, or the token this server could not read, or nothing.
  attr :cell, :map, required: true
  attr :slug, :string, required: true
  attr :show, :map, default: %{}

  def crosstable_cell(assigns) do
    {token, note} = Tournament.result_parts(assigns.cell.result)

    assigns =
      assigns
      # `token` is only ever rendered for a result this server cannot read -
      # see the score below. A known one is shown as the row player's own
      # points instead, because the token belongs to the board and the cell
      # belongs to one seat of it.
      |> assign(:token, token)
      |> assign(:note, note_label(note))
      |> assign(:cards?, shown?(assigns.show, :player_cards))

    ~H"""
    <td
      class={["xt-cell", @cell.kind == :none && "xt-empty"]}
      title={@cell.kind == :none && gettext("no game published for this round")}
    >
      <%= case @cell.kind do %>
        <% :game -> %>
          <span class="xt-game">
            <a
              :if={@cards? && @cell.opponent_no}
              href={~p"/t/#{@slug}/player/#{@cell.opponent_no}"}
              class="player xt-opp"
              data-player={@cell.opponent_no}
            >{@cell.opponent_no}</a>
            <span :if={not @cards? and @cell.opponent_no} class="xt-opp">{@cell.opponent_no}</span>
            <abbr
              :if={@cell.colour}
              class={["xt-colour", colour_class(@cell.colour)]}
              title={colour_word(@cell.colour)}
            >{colour_mark(@cell.colour)}</abbr>
            <span :if={not is_nil(@cell.points)} class="xt-score">{number(@cell.points)}</span>
            <%!-- A token from a newer client, shown as it arrived. Neither
                  seat gets a score from it: guessing which half of
                  `1-0ADJ` belongs to whom would be inventing a result, and
                  printing the whole token in both rows would tell the loser
                  they won. --%>
            <span :if={is_nil(@cell.points) and @token} class="xt-score xt-token">{@token}</span>
            <span
              :if={is_nil(@cell.points) and is_nil(@token)}
              class="unreported"
              title={gettext("not yet reported")}
            >-</span>
          </span>
          <%!-- Forfeit and unrated, said in words under the score. A forfeit
                is worth its point and is still not a game that was played,
                and this is the one place on the site where the difference has
                to survive being one character wide. --%>
          <span :if={@note} class="xt-note">{@note}</span>
        <% :bye -> %>
          <span class="xt-game">
            <span class="xt-score">{number(@cell.points)}</span>
          </span>
          <%!-- The arbiter's own word for it, and their own value beside it.
                A bare `1` in this column would be indistinguishable from a
                win. The vacated seat's result token is deliberately not
                repeated here - "seat vacated" already says the game was not
                played, which is the only thing the token was carrying. --%>
          <span class="xt-note">{bye_kind(@cell.bye)}</span>
        <% _nothing -> %>
          <%!-- A published round this player is not listed in: unpaired, or a
                board the arbiter hid. The payload cannot tell the two apart -
                a hidden board is absent rather than flagged - so the cell
                says nothing rather than choosing. Empty and not a zero: a
                zero is a game somebody lost. --%>
      <% end %>
    </td>
    """
  end

  # The colour mark, and the word behind it.
  #
  # `w` and `b` are NOT translated, which is a decision rather than an
  # oversight. They are the notation a TRF file, a printed pairing sheet and
  # every other results site already use, so an arbiter checking this page
  # against their own file reads the same two letters in every language.
  # Translating them would also collide across languages rather than merely
  # differ: French `b` is blancs and English `b` is black, so the same letter
  # would mean opposite things on two versions of one page.
  #
  # The word itself is on the mark as an `<abbr title>`, and the footnote
  # under the table spells both letters out in the reader's own language -
  # because a tooltip is not available to somebody reading this on a phone.
  defp colour_mark(:white), do: "w"
  defp colour_mark(:black), do: "b"

  defp colour_word(:white), do: gettext("White")
  defp colour_word(:black), do: gettext("Black")

  defp colour_class(:white), do: "xt-white"
  defp colour_class(:black), do: "xt-black"

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
    <p :if={@boards == []} class="empty">{gettext("No boards were published for this round.")}</p>

    <div :if={@boards != []} class="scroller">
      <table class="pairings">
        <thead>
          <tr>
            <th class="num" scope="col">{gettext("Bd")}</th>
            <th :if={@show.rating} class="num" scope="col">{gettext("Elo")}</th>
            <th
              :if={@show.pairing_scores}
              class="num"
              scope="col"
              title={gettext("Points going into this round")}
            >
              {gettext("Pts")}
            </th>
            <th scope="col">{gettext("White")}</th>
            <th class="num" scope="col">{gettext("Result")}</th>
            <th scope="col">{gettext("Black")}</th>
            <th
              :if={@show.pairing_scores}
              class="num"
              scope="col"
              title={gettext("Points going into this round")}
            >
              {gettext("Pts")}
            </th>
            <th :if={@show.rating} class="num" scope="col">{gettext("Elo")}</th>
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
    <span :if={is_nil(@points)} class="unreported" title={gettext("an earlier round is not public")}>
      -
    </span>
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
            <th scope="col">{gettext("Player")}</th>
            <th :if={@show.rating} class="num" scope="col">{gettext("Elo")}</th>
            <th scope="col">{gettext("Bye")}</th>
            <th class="num" scope="col">{gettext("Points")}</th>
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
            <%!-- The result only exists on a vacated seat, where the points
                  alone would not explain themselves: "0" against a name reads
                  as a zero-point bye until it says the game was forfeited. --%>
            <td>
              {bye_kind(bye["kind"])}
              <span :if={bye["result"]} class="quiet">(<.result token={bye["result"]} />)</span>
            </td>
            <td class="num">{number(bye["points"])}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  A round's boards, projected: readable from across a room, and left to the
  script below to page through when they do not all fit on the screen in
  front of them.

  Reached via `?display=1` on the round's own URL, so this is the same
  document as `pairings_table/1` above and not a separate page - see
  `TournamentController.round/2`. Two differences from the ordinary table:
  every name is plain text rather than a link, because a tap here pauses the
  cycle rather than following it somewhere; and there is no rating or score
  column, because a hall screen must never need to scroll sideways to find a
  board, and neither serves what a projector is actually for - finding your
  name and seeing who you are playing.

  Byes are listed underneath, statically - useful to a player checking
  whether they are even on a board, and deliberately NOT part of the cycle,
  same as standings: nobody watches a hall screen for their own bye.

  The pagination itself is client-side JavaScript, and has to be: this is a
  plain controller with no socket, and a hall screen must keep cycling
  through a venue's wifi wobbling, not stop the moment it does.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true

  def projector_round(assigns) do
    assigns =
      assigns
      |> assign(:boards, Tournament.boards(assigns.round))
      |> assign(:show, display_rules(assigns.payload))

    ~H"""
    <section
      class="projector"
      data-projector
      aria-label={gettext("Round pairings, projector view")}
    >
      <header class="projector-head">
        <h1>{Tournament.name(@payload)}</h1>
        <%!-- Gated for the same reason as the ordinary round heading: a hall
              screen is the most public surface this app has, and the date it
              shows is the round's, which the "dates" tick covers. --%>
        <p class="projector-round">
          {Tournament.round_heading(@payload, @round["number"])}
          <span :if={@show.dates && @round["date"]}>{@round["date"]}</span>
        </p>
      </header>

      <p :if={@boards == []} class="empty">{gettext("No boards were published for this round.")}</p>

      <div :if={@boards != []} class="projector-table-wrap" id="projector-boards">
        <table class="pairings projector-pairings">
          <thead>
            <tr>
              <th class="num" scope="col">{gettext("Bd")}</th>
              <th scope="col">{gettext("White")}</th>
              <th class="num" scope="col">{gettext("Result")}</th>
              <th scope="col">{gettext("Black")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={board <- @boards}>
              <td class="num">{Tournament.board_label(board)}</td>
              <td>
                <.player_link
                  slug={@slug}
                  no={board["white"]}
                  player={@players[board["white"]]}
                  show={@show}
                  cards?={false}
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
                  cards?={false}
                  detail
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Hidden until the script decides otherwise. A counter reading "1 of
            1" only tells a viewer that nobody checked, so this stays out of
            the accessibility tree entirely whenever every board already fits. --%>
      <%!-- The counter's wording is an attribute rather than text because the
            script rewrites it on every turn of the cycle, and a string built
            in JavaScript is a string outside the catalogue. --%>
      <div
        :if={@boards != []}
        class="projector-foot"
        id="projector-foot"
        data-page-label={gettext("Page %{page} of %{count}", page: "{page}", count: "{count}")}
        hidden
      >
        <span class="projector-page" id="projector-page"></span>
        <span class="projector-paused" id="projector-paused" hidden>
          {gettext("Paused - tap or press space to resume")}
        </span>
        <%!-- Not decoration: someone looking for board 47 needs to know their
              page is coming and roughly when, or a rotating screen is worse
              than a still one. --%>
        <span class="projector-bar" id="projector-bar" aria-hidden="true">
          <span class="projector-bar-fill" id="projector-bar-fill"></span>
        </span>
      </div>

      <section
        :if={Tournament.show?(@payload, "byes") and Tournament.byes(@round) != []}
        class="projector-byes"
      >
        <h2>{gettext("Byes")}</h2>
        <.byes_table slug={@slug} round={@round} players={@players} payload={@payload} />
      </section>
    </section>

    <script>
      (() => {
        const CYCLE_MS = 12000;
        // Independent of, and slower than, the site-wide 20-second refresher
        // in the root layout (which is switched off entirely on this page -
        // see the layout for why): that one replaces a whole region and would
        // wipe out which page is showing and the running timer along with it.
        // This swaps only the rows.
        const REFRESH_MS = 60000;

        const section = document.querySelector("[data-projector]");
        const wrap = document.getElementById("projector-boards");
        if (!section || !wrap) { return; }

        const table = wrap.querySelector("table");
        const tbody = table.querySelector("tbody");
        const thead = table.querySelector("thead");
        const foot = document.getElementById("projector-foot");
        const pageLabel = document.getElementById("projector-page");
        const pausedLabel = document.getElementById("projector-paused");
        const bar = document.getElementById("projector-bar");
        const barFill = document.getElementById("projector-bar-fill");

        let rowsPerPage = 1;
        let page = 0;
        let paused = false;
        let cycleTimer = null;

        const rows = () => Array.from(tbody.querySelectorAll("tr"));

        // How many rows the glass actually holds, measured against an
        // already-rendered row rather than guessed - so nothing has to be
        // configured for a particular television.
        const measure = () => {
          const sample = rows()[0];
          if (!sample) { return 1; }

          const rowHeight = sample.getBoundingClientRect().height;
          if (rowHeight <= 0) { return rowsPerPage || 1; }

          const top = table.getBoundingClientRect().top;
          const headHeight = thead ? thead.getBoundingClientRect().height : 0;
          // Room for the page counter and bar below, so the last row is
          // never half-clipped at the bottom edge.
          const chrome = headHeight + 72;
          const usable = window.innerHeight - top - chrome;

          return Math.max(Math.floor(usable / rowHeight), 1);
        };

        const pageCount = () => Math.max(Math.ceil(rows().length / rowsPerPage), 1);

        // Shows the current page's rows and the counter beneath them.
        // Deliberately does not touch the progress bar's animation - a
        // resize or a data refresh must not restart a countdown somebody is
        // already watching.
        const applyPage = () => {
          const count = pageCount();
          page = Math.min(page, count - 1);

          rows().forEach((row, i) => {
            row.hidden = Math.floor(i / rowsPerPage) !== page;
          });

          if (count > 1) {
            foot.hidden = false;
            // The sentence comes from the server, already in the reader's
            // language, with the two numbers left as placeholders.
            pageLabel.textContent = (foot.dataset.pageLabel || "{page} / {count}")
              .replace("{page}", page + 1)
              .replace("{count}", count);
            pausedLabel.hidden = !paused;
            bar.hidden = paused;
          } else {
            // Every board fits on one screen: no counter, no bar, no timer.
            foot.hidden = true;
          }
        };

        // Restarts the sweep from empty. Called only where the countdown
        // itself actually restarts - a page turning over, or a resume - so
        // the bar and the timer that drives it can never drift apart.
        const restartBar = () => {
          if (paused) { return; }
          barFill.classList.remove("running");
          void barFill.offsetWidth;
          barFill.style.animationDuration = `${CYCLE_MS}ms`;
          barFill.classList.add("running");
        };

        const scheduleCycle = () => {
          if (cycleTimer) { clearInterval(cycleTimer); }
          cycleTimer = paused ? null : setInterval(advance, CYCLE_MS);
        };

        function advance() {
          const count = pageCount();
          if (paused || count <= 1) { return; }
          page = (page + 1) % count;
          applyPage();
          restartBar();
        }

        const refit = () => {
          rowsPerPage = measure();
          applyPage();
        };

        // A tap holds the page it is on rather than jumping back to the
        // start, so a player mid-read is not chased off their own board.
        const togglePause = () => {
          paused = !paused;
          applyPage();
          scheduleCycle();
          restartBar();
        };

        section.addEventListener("click", (e) => {
          // Real links and buttons (the theme picker lives outside this
          // section, but stay defensive) keep their own behaviour.
          if (e.target.closest("a, button")) { return; }
          togglePause();
        });

        document.addEventListener("keydown", (e) => {
          if (e.key !== " " && e.code !== "Space") { return; }

          // Do not steal space from something else on the page that wants
          // it - the theme picker's own trigger, chiefly.
          const tag = document.activeElement && document.activeElement.tagName;
          if (["BUTTON", "SUMMARY", "A", "INPUT", "TEXTAREA", "SELECT"].includes(tag)) {
            return;
          }

          e.preventDefault();
          togglePause();
        });

        let resizeTimer = null;

        const onResize = () => {
          clearTimeout(resizeTimer);
          resizeTimer = setTimeout(refit, 150);
        };

        window.addEventListener("resize", onResize);
        window.addEventListener("orientationchange", refit);

        // ---- keeping the boards current --------------------------------
        //
        // A re-fetch of this same URL and a swap of only the <tbody>, not a
        // reload - a reload would restart the cycle and blink the screen,
        // which is exactly what somebody watching this from across a hall
        // must never see.
        const refreshRows = () => {
          if (document.hidden) { return; }

          fetch(window.location.href, { headers: { accept: "text/html" } })
            .then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
            .then((html) => {
              const doc = new DOMParser().parseFromString(html, "text/html");
              const fresh = doc.querySelector("#projector-boards tbody");
              if (!fresh || fresh.innerHTML === tbody.innerHTML) { return; }

              tbody.innerHTML = fresh.innerHTML;
              refit();
            })
            .catch(() => {
              // The hall's wifi wobbles. The board stays as it was rather
              // than blank - stale is better than gone.
            });
        };

        refit();
        if (pageCount() > 1) { restartBar(); }
        scheduleCycle();
        setInterval(refreshRows, REFRESH_MS);
        document.addEventListener("visibilitychange", () => {
          if (!document.hidden) { refreshRows(); }
        });
      })();
    </script>
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
            <th class="num" scope="col">{gettext("Rd")}</th>
            <th scope="col">{gettext("Colour")}</th>
            <th class="num" scope="col" title={gettext("Opponent's pairing number")}>
              {gettext("No")}
            </th>
            <th :if={@show.federation} scope="col">{gettext("Nat")}</th>
            <th :if={@show.title} scope="col">{gettext("Tit")}</th>
            <th scope="col">{gettext("Opponent")}</th>
            <th :if={@show.rating} class="num" scope="col">{gettext("Elo")}</th>
            <th class="num" scope="col" title={gettext("Opponent's total")}>{gettext("Pts")}</th>
            <th class="num" scope="col">{gettext("Result")}</th>
            <th class="num" scope="col">{gettext("Score")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={entry <- @card} class={entry.kind == :unpublished && "withheld"}>
            <td class="num">{entry.round}</td>
            <%= case entry.kind do %>
              <% :game -> %>
                <td>{if(entry.colour == :white, do: gettext("White"), else: gettext("Black"))}</td>
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
                <%!-- The bye's label sits where the opponent's NAME sits, under
                      "Opponent", with the cells before it left blank - the way
                      the arbiter's own player card reads it. It used to span
                      from "No" onwards, so the text started two or three
                      columns to the left of every name above and below it and
                      read as if it had landed in the wrong column. --%>
                <td></td>
                <td></td>
                <td :if={@show.federation}></td>
                <td :if={@show.title}></td>
                <td colspan={2 + count_if([@show.rating])} class="quiet">{bye_kind(entry.bye)}</td>
                <td class="num">{number(entry.points)}</td>
              <% :unpublished -> %>
                <td colspan={@game_span + 2} class="quiet">{gettext("not published")}</td>
              <% _no_game -> %>
                <td colspan={@game_span + 2} class="quiet">
                  {gettext("no game published for this round")}
                </td>
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
      ~w(standings crosstable pairings player_cards byes rating title federation club category
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
      <span class="name">
        {(@player && @player["name"]) || gettext("Player %{number}", number: @no)}
      </span>
    </a>
    <span :if={@no && not @cards?} class="player">
      <span :if={@detail && shown?(@show, :title) && @player && @player["title"]} class="title">
        {@player["title"]}
      </span>
      <span class="name">
        {(@player && @player["name"]) || gettext("Player %{number}", number: @no)}
      </span>
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
        {gettext("of %{total}, on %{points}",
          total: length(Tournament.standings_rows(@payload)),
          points: number(@row["points"])
        )}
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
      {gettext("This tournament publishes no breakdown of its tie-breaks.")}
    </p>

    <%!-- The placing above is a claim, so the same caveat belongs here: what
          is listed may not be everything that put them there. --%>
    <p :if={Tournament.tiebreaks_withheld?(@payload)} class="footnote">
      {gettext("The order also uses tie-breaks this tournament does not publish.")}
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
      ngettext("from %{count} round", "from %{count} rounds", counted),
      virtual > 0 && ngettext("%{count} unplayed", "%{count} unplayed", virtual),
      cut > 0 && ngettext("%{count} discarded", "%{count} discarded", cut),
      excluded > 0 && ngettext("%{count} not counted", "%{count} not counted", excluded)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

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
      <h3>{gettext("Where the tie-breaks come from")}</h3>

      <div :for={code <- @codes} class="working-block">
        <h4>
          {@labels[code]}
          <span class="num strong">{number(@working[code]["total"])}</span>
        </h4>

        <div class="scroller">
          <table class="working-table">
            <thead>
              <tr>
                <th class="num" scope="col">{gettext("Rd")}</th>
                <th scope="col">{gettext("From")}</th>
                <th class="num" scope="col">{gettext("Value")}</th>
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
        {gettext(
          "These are the arbiter's numbers, published with the results - this page does not calculate them. An unplayed round contributes a notional opponent under FIDE Article 16 rather than a real one, which is why some rows name nobody."
        )}
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
    <span :if={Tournament.part_kind(@part) == "cut"} class="tag">{gettext("discarded")}</span>
    <span :if={Tournament.part_kind(@part) == "excluded" and @part["opponent"]} class="tag">
      {gettext("not counted")}
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
      "excluded" -> gettext("not counted")
      _virtual_or_cut -> gettext("unplayed round")
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
        {gettext("running score")}
        <span :if={@label}>
          <span class="chart-key chart-key-bar"></span>
          {gettext("what each round gave to %{tiebreak}", tiebreak: @label)}
        </span>
      </figcaption>
    </figure>
    """
  end

  defp chart_title(nil), do: gettext("The player's running score by round.")

  defp chart_title(label) do
    gettext(
      "The player's running score by round, and each round's contribution to %{tiebreak}.",
      tiebreak: label
    )
  end

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
    assigns = assigns |> assign(:base, base) |> assign(:note, note_label(note))

    ~H"""
    <span class="result">
      <span :if={@base} class="token">{@base}</span>
      <span :if={is_nil(@base)} class="unreported" title={gettext("not yet reported")}>-</span>
      <span :if={@note} class="note">{@note}</span>
    </span>
    """
  end

  # `Tournament.result_parts/1` names the marker; the wording is this
  # module's, the same division of labour the moduledoc sets out. A marker
  # from a newer client passes through as it arrived rather than vanishing.
  defp note_label("forfeit"), do: gettext("forfeit")
  defp note_label("unrated"), do: gettext("unrated")
  defp note_label(other), do: other

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
  def bye_kind("pairing-allocated"), do: gettext("pairing-allocated bye")
  def bye_kind("half-point"), do: gettext("half-point bye")
  def bye_kind("zero-point"), do: gettext("zero-point bye")
  def bye_kind("full-point"), do: gettext("full-point bye")
  def bye_kind("absent"), do: gettext("absent")

  # Not a bye at all, which is exactly why it has its own word. The arbiter
  # emptied one seat of a board and recorded a result against it anyway - a
  # forfeit, usually. Every one of these used to arrive labelled
  # "pairing-allocated" and carrying the tournament's bye value, so a player
  # who forfeited appeared here with a full point for the round and a running
  # total that disagreed with the standings on the next page. The arbiter's
  # app now sends what happened; this is where it gets a name.
  def bye_kind("vacated-seat"), do: gettext("seat vacated")

  def bye_kind(kind) when is_binary(kind), do: kind
  def bye_kind(_absent), do: gettext("bye")
end
