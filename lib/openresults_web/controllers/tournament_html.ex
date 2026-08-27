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
  attr :current, :any, required: true, doc: ":standings, {:round, n} or {:player, no}"

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

    ~H"""
    <header class="masthead">
      <h1>{Tournament.name(@payload)}</h1>

      <p class="details">
        <span :if={@info["city"]}>{@info["city"]}</span>
        <span :if={@info["federation"]}>{@info["federation"]}</span>
        <span :if={dates(@info)}>{dates(@info)}</span>
        <span :if={@info["arbiter"]}>Arbiter: {@info["arbiter"]}</span>
        <span :if={@info["fide_rated"] == true}>FIDE rated</span>
      </p>

      <nav class="rounds" aria-label="Rounds">
        <a href={~p"/t/#{@slug}"} class={["chip", @current == :standings && "current"]}>
          Standings
        </a>
        <%= for {n, published?} <- @slots do %>
          <a
            :if={published?}
            href={~p"/t/#{@slug}/round/#{n}"}
            class={["chip", @current == {:round, n} && "current"]}
          >
            {n}
          </a>
          <span :if={not published?} class="chip withheld" title="not published">
            {n}<span class="visually-hidden">, not published</span>
          </span>
        <% end %>
      </nav>
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

    ~H"""
    <p :if={@rows == []} class="empty">
      No standings have been published for this tournament yet.
    </p>

    <div :if={@rows != []} class="scroller">
      <table class="standings">
        <thead>
          <tr>
            <th class="num" scope="col">#</th>
            <th scope="col">Player</th>
            <th class="num" scope="col">Rating</th>
            <%= if @keizer? do %>
              <th class="num" scope="col">Value</th>
              <th class="num" scope="col">Keizer points</th>
              <th class="num" scope="col">Score</th>
            <% else %>
              <th class="num" scope="col">Points</th>
              <th :for={tiebreak <- @tiebreaks} class="num" scope="col">
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
                detail
              />
            </td>
            <td class="num">{@players[row["player"]]["rating"]}</td>
            <%= if @keizer? do %>
              <td class="num">{number(row["value"])}</td>
              <td class="num strong">{number(row["points"])}</td>
              <td class="num">{number(row["score"])}</td>
            <% else %>
              <td class="num strong">{number(row["points"])}</td>
              <td :for={{_tiebreak, at} <- Enum.with_index(@tiebreaks)} class="num">
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
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true

  def pairings_table(assigns) do
    assigns = assign(assigns, :boards, Tournament.boards(assigns.round))

    ~H"""
    <p :if={@boards == []} class="empty">No boards were published for this round.</p>

    <div :if={@boards != []} class="scroller">
      <table class="pairings">
        <thead>
          <tr>
            <th class="num" scope="col">Bd</th>
            <th scope="col">White</th>
            <th class="num" scope="col">Result</th>
            <th scope="col">Black</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={board <- @boards}>
            <td class="num">{board["board"]}</td>
            <td>
              <.player_link slug={@slug} no={board["white"]} player={@players[board["white"]]} />
            </td>
            <td class="num"><.result token={board["result"]} /></td>
            <td>
              <.player_link slug={@slug} no={board["black"]} player={@players[board["black"]]} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  A round's byes.

  The kind and the value both come from the payload. The value is
  configurable, so a half-point bye worth something other than a half point is
  the arbiter's decision to state and not this app's to assume.
  """
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true

  def byes_table(assigns) do
    assigns = assign(assigns, :byes, Tournament.byes(assigns.round))

    ~H"""
    <div :if={@byes != []} class="scroller">
      <table class="byes">
        <thead>
          <tr>
            <th scope="col">Player</th>
            <th scope="col">Bye</th>
            <th class="num" scope="col">Points</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={bye <- @byes}>
            <td><.player_link slug={@slug} no={bye["player"]} player={@players[bye["player"]]} /></td>
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

  def card_table(assigns) do
    ~H"""
    <div class="scroller">
      <table class="card">
        <thead>
          <tr>
            <th class="num" scope="col">Rd</th>
            <th scope="col">Colour</th>
            <th scope="col">Opponent</th>
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
                <td>
                  <.player_link slug={@slug} no={entry.opponent_no} player={entry.opponent} detail />
                </td>
                <td class="num"><.result token={entry.result} /></td>
              <% :bye -> %>
                <td></td>
                <td class="quiet">{bye_kind(entry.bye)}</td>
                <td class="num">{number(entry.points)}</td>
              <% :unpublished -> %>
                <td colspan="3" class="quiet">not published</td>
              <% _no_game -> %>
                <td colspan="3" class="quiet">no game published for this round</td>
            <% end %>
            <td class="num strong">{number(entry.score)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
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
  attr :detail, :boolean, default: false, doc: "show title and rating alongside the name"

  def player_link(assigns) do
    ~H"""
    <a :if={@no} href={~p"/t/#{@slug}/player/#{@no}"} class="player">
      <span :if={@detail && @player && @player["title"]} class="title">{@player["title"]}</span>
      <span class="name">{(@player && @player["name"]) || "Player #{@no}"}</span>
      <span :if={@detail && @player && @player["rating"]} class="rating">{@player["rating"]}</span>
    </a>
    <span :if={is_nil(@no)} class="player">-</span>
    """
  end

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
