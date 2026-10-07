defmodule OpenResultsWeb.GameLive do
  @moduledoc """
  One game, move by move. `GET /t/:slug/live/:round/:board`.

  A large board, both players with their clocks, the move list - click a move
  to see the position after it - and the arrow keys to step through. While
  nothing is selected the page follows the game: a move that arrives is on the
  board a moment later. Selecting an earlier move stops following until
  "Live" is pressed, so a spectator studying move 20 is not dragged to move
  34. There is no engine and no evaluation.

  Keys: left and right step, up and down (or Home and End) jump to the start
  and to the latest move, `f` flips the board.

  Like `OpenResultsWeb.BoardsLive`, this page re-reads the game itself and is
  never served from the page cache; see there for the delay and the tick.
  What is shown is `OpenResultsWeb.LiveBoardsData`'s rule.
  """

  use OpenResultsWeb, :live_view

  import OpenResultsWeb.LiveBoardsComponents

  alias OpenResults.Chess
  alias OpenResults.LiveBoards
  alias OpenResults.TournamentEvents
  alias OpenResults.Tournaments
  alias OpenResultsWeb.LiveBoardsData
  alias OpenResultsWeb.Tournament

  @tick :timer.seconds(15)

  @impl true
  def mount(%{"slug" => slug, "round" => round, "board" => board}, session, socket) do
    locale = Map.get(session, "locale") || OpenResultsWeb.Locale.default()
    Gettext.put_locale(OpenResultsWeb.Gettext, locale)

    round = parse(round)
    board = parse(board)

    if connected?(socket) do
      TournamentEvents.subscribe(slug)
      LiveBoards.subscribe(slug)
      Process.send_after(self(), :tick, @tick)
    end

    socket =
      socket
      |> assign(
        slug: slug,
        locale: locale,
        round: round,
        board: board,
        payload: nil,
        snapshot_id: nil,
        title: slug,
        tile: nil,
        delay: 0,
        selected: nil,
        flip: false,
        page_title: gettext("Live game")
      )
      |> load()

    {:ok, socket, layout: false}
  end

  defp parse(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _junk -> nil
    end
  end

  defp load(socket) do
    %{slug: slug, round: round, board: board} = socket.assigns

    case Tournaments.public_latest(slug) do
      nil ->
        assign(socket, payload: nil, snapshot_id: nil, tile: nil)

      snapshot ->
        payload = snapshot.payload
        tile = round && board && LiveBoardsData.tile(payload, slug, round, board)

        socket
        |> assign(
          payload: payload,
          snapshot_id: snapshot.id,
          title: Tournament.name(payload),
          tile: tile || nil,
          delay: LiveBoards.delay_minutes(slug),
          page_title: if(tile, do: page_title(tile), else: gettext("Live game"))
        )
        |> clamp()
    end
  end

  defp page_title(tile) do
    "#{(tile.white && tile.white.name) || "-"} - #{(tile.black && tile.black.name) || "-"}"
  end

  # A selection past the end of the game it points into stops being one.
  defp clamp(%{assigns: %{selected: nil}} = socket), do: socket

  defp clamp(%{assigns: %{tile: %{view: %{plies: plies, ply: ply}}, selected: n}} = socket) do
    cond do
      length(plies) != ply -> assign(socket, selected: nil)
      n >= ply -> assign(socket, selected: nil)
      true -> socket
    end
  end

  defp clamp(socket), do: assign(socket, selected: nil)

  defp refresh(%{assigns: %{payload: nil}} = socket), do: load(socket)

  defp refresh(socket) do
    %{slug: slug, round: round, board: board, payload: payload} = socket.assigns

    tile = round && board && LiveBoardsData.tile(payload, slug, round, board)

    socket
    |> assign(tile: tile || nil, delay: LiveBoards.delay_minutes(slug))
    |> clamp()
  end

  # --- messages ----------------------------------------------------------------

  @impl true
  def handle_info(
        {:live_board, slug, round, board},
        %{assigns: %{slug: slug, round: round, board: board}} = socket
      ) do
    delay_ms = :timer.minutes(LiveBoards.delay_minutes(slug))

    if delay_ms == 0 do
      {:noreply, refresh(socket)}
    else
      Process.send_after(self(), :refresh, delay_ms + 50)
      {:noreply, socket}
    end
  end

  def handle_info({:live_board, _slug, _round, _board}, socket), do: {:noreply, socket}
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}
  def handle_info({:live_delay, _slug}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:tournament_changed, slug}, %{assigns: %{slug: slug}} = socket),
    do: {:noreply, load(socket)}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, refresh(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- events ------------------------------------------------------------------

  @impl true
  def handle_event("goto", %{"ply" => ply}, socket), do: {:noreply, select(socket, parse(ply))}
  def handle_event("first", _params, socket), do: {:noreply, select(socket, 0)}
  def handle_event("last", _params, socket), do: {:noreply, assign(socket, selected: nil)}
  def handle_event("live", _params, socket), do: {:noreply, assign(socket, selected: nil)}
  def handle_event("prev", _params, socket), do: {:noreply, step(socket, -1)}
  def handle_event("next", _params, socket), do: {:noreply, step(socket, 1)}

  def handle_event("flip", _params, socket),
    do: {:noreply, assign(socket, flip: !socket.assigns.flip)}

  def handle_event("key", %{"key" => key}, socket) do
    case key do
      "ArrowLeft" -> {:noreply, step(socket, -1)}
      "ArrowRight" -> {:noreply, step(socket, 1)}
      k when k in ["ArrowUp", "Home"] -> {:noreply, select(socket, 0)}
      k when k in ["ArrowDown", "End"] -> {:noreply, assign(socket, selected: nil)}
      k when k in ["f", "F"] -> {:noreply, assign(socket, flip: !socket.assigns.flip)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp step(socket, by), do: select(socket, current_ply(socket.assigns) + by)

  defp select(%{assigns: %{tile: %{view: %{plies: plies, ply: ply}}}} = socket, n)
       when is_integer(n) and length(plies) == ply do
    cond do
      n >= ply -> assign(socket, selected: nil)
      n <= 0 -> assign(socket, selected: 0)
      true -> assign(socket, selected: n)
    end
  end

  defp select(socket, _n), do: socket

  defp current_ply(%{tile: %{view: %{ply: ply}}, selected: nil}), do: ply
  defp current_ply(%{selected: n}), do: n

  # --- what is on the board ----------------------------------------------------

  # {fen, highlighted squares, ply shown}
  defp shown(%{plies: plies, ply: ply} = view, selected) do
    n = selected || ply

    cond do
      n >= ply ->
        {view.fen, view.last, ply}

      n <= 0 ->
        {view.start_fen, nil, 0}

      true ->
        entry = Enum.at(plies, n - 1)
        {entry["fen"], {entry["from"], entry["to"]}, n}
    end
  end

  # The move list as rows: `%{number, white: {ply, san} | nil, black: ...}`.
  defp rows(%{plies: plies, start_fen: start}) do
    {turn, number} =
      case Chess.parse_fen(start) do
        {:ok, position} -> {position.turn, position.fullmove}
        _error -> {:w, 1}
      end

    entries =
      plies
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, ply} -> {ply, entry["san"]} end)

    entries = if turn == :b, do: [nil | entries], else: entries

    entries
    |> Enum.chunk_every(2)
    |> Enum.with_index(number)
    |> Enum.map(fn {pair, n} ->
      %{number: n, white: Enum.at(pair, 0), black: Enum.at(pair, 1)}
    end)
  end

  # --- the page ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign_view(assigns)

    ~H"""
    <.piece_sprite />
    <div
      id="lb-game-page"
      phx-window-keydown="key"
    >
      <.shell locale={@locale} path={current_path(@slug, @round, @board)} slug={@slug} title={@title}>
        <h1 :if={is_nil(@tile)} id="lb-game-title-empty">{gettext("Live game")}</h1>
        <p :if={is_nil(@payload)} id="lb-unavailable" class="empty">
          {gettext("Nothing is published for this tournament at the moment.")}
        </p>

        <p :if={@payload && is_nil(@tile)} id="lb-no-game" class="empty">
          {gettext("This board is not published.")}
        </p>

        <div :if={@tile} id="lb-game" class="lb-game">
          <h1 id="lb-game-title" class="lb-game-title">
            {gettext("Round %{round}, board %{board}", round: @tile.round, board: @tile.label)}
          </h1>
          <p class="details lb-game-details">
            <span id="lb-game-status" class={["lb-badge", "lb-status-#{@status}"]}>
              {status_label(@status, @result)}
            </span>
            <span :if={@result} id="lb-game-result" class="lb-result">
              {elem(@result, 0)}<span :if={elem(@result, 1)} class="lb-provisional"> *</span>
            </span>
            <span :if={@delay > 0} id="lb-delay">
              {ngettext(
                "shown %{count} minute behind the game",
                "shown %{count} minutes behind the game",
                @delay
              )}
            </span>
            <span :if={is_nil(@tile.view)} id="lb-not-started">
              {gettext("The game has not started yet.")}
            </span>
          </p>

          <div class="lb-game-layout">
            <section class="lb-board-column" aria-label={gettext("Board")}>
              <.player_line tile={@tile} colour={@top} clocks={@clocks} />
              <.board_svg
                id="lb-game-board"
                fen={@fen}
                last={@marked}
                flip={@flip}
                coords={true}
                label={tile_label(@tile)}
                class="lb-board-large"
              />
              <.player_line tile={@tile} colour={@bottom} clocks={@clocks} />

              <div class="lb-controls" role="group" aria-label={gettext("Step through the game")}>
                <button
                  type="button"
                  id="lb-first"
                  phx-click="first"
                  class="lb-btn"
                  disabled={@steps == 0}
                  aria-label={gettext("Start of the game")}
                  title={gettext("Start of the game")}
                >
                  &laquo;
                </button>
                <button
                  type="button"
                  id="lb-prev"
                  phx-click="prev"
                  class="lb-btn"
                  disabled={@steps == 0 or @shown_ply == 0}
                  aria-label={gettext("Previous move")}
                  title={gettext("Previous move")}
                >
                  &lsaquo;
                </button>
                <button
                  type="button"
                  id="lb-next"
                  phx-click="next"
                  class="lb-btn"
                  disabled={@steps == 0 or @following?}
                  aria-label={gettext("Next move")}
                  title={gettext("Next move")}
                >
                  &rsaquo;
                </button>
                <button
                  type="button"
                  id="lb-last"
                  phx-click="last"
                  class="lb-btn"
                  disabled={@steps == 0 or @following?}
                  aria-label={gettext("Latest move")}
                  title={gettext("Latest move")}
                >
                  &raquo;
                </button>
                <button type="button" id="lb-flip" phx-click="flip" class="lb-btn lb-btn-text">
                  {gettext("Flip board")}
                </button>
                <button
                  :if={not @following? and @status == :live}
                  type="button"
                  id="lb-follow"
                  phx-click="live"
                  class="lb-btn lb-btn-text lb-btn-live"
                >
                  {gettext("Follow live")}
                </button>
              </div>
            </section>

            <section class="lb-side-column" aria-label={gettext("Moves")}>
              <h2 class="lb-moves-title">{gettext("Moves")}</h2>
              <p :if={@rows == []} id="lb-no-moves" class="quiet">
                {gettext("No moves yet.")}
              </p>
              <ol :if={@rows != []} id="lb-moves" class="lb-moves">
                <li :for={row <- @rows} id={"lb-row-#{row.number}"} class="lb-move-row">
                  <span class="lb-move-number">{row.number}.</span>
                  <.move_button cell={row.white} shown={@shown_ply} />
                  <.move_button cell={row.black} shown={@shown_ply} />
                </li>
              </ol>
              <p class="lb-game-links">
                <a
                  id="lb-pgn"
                  class="lb-btn lb-btn-text"
                  href={~p"/t/#{@slug}/live/#{@tile.round}/#{@tile.board}/pgn"}
                  download
                >
                  {gettext("Download PGN")}
                </a>
                <.link
                  id="lb-back"
                  class="lb-btn lb-btn-text"
                  navigate={~p"/t/#{@slug}/live/#{@tile.round}"}
                >
                  {gettext("All boards of this round")}
                </.link>
              </p>
            </section>
          </div>
        </div>
      </.shell>
    </div>
    """
  end

  attr :cell, :any, default: nil
  attr :shown, :integer, required: true

  defp move_button(%{cell: nil} = assigns), do: ~H|<span class="lb-move lb-move-empty"></span>|

  defp move_button(%{cell: {ply, san}} = assigns) do
    assigns = assign(assigns, ply: ply, san: san)

    ~H"""
    <button
      type="button"
      id={"lb-ply-#{@ply}"}
      class={["lb-move", @ply == @shown && "is-current"]}
      phx-click="goto"
      phx-value-ply={@ply}
      aria-current={@ply == @shown && "step"}
    >
      {@san}
    </button>
    """
  end

  defp assign_view(%{tile: nil} = assigns) do
    assign(assigns,
      status: :waiting,
      result: nil,
      clocks: nil,
      fen: Chess.start_fen(),
      marked: nil,
      rows: [],
      steps: 0,
      shown_ply: 0,
      following?: true,
      top: "black",
      bottom: "white"
    )
  end

  defp assign_view(%{tile: tile} = assigns) do
    {fen, marked, shown_ply} =
      case tile.view do
        nil -> {Chess.start_fen(), nil, 0}
        view -> shown(view, assigns.selected)
      end

    view = tile.view
    steps = if view && length(view.plies) == view.ply, do: view.ply, else: 0

    assign(assigns,
      status: status(tile),
      result: LiveBoardsData.result(tile),
      clocks: view && view.clocks,
      fen: fen,
      marked: marked,
      rows: if(view && steps > 0, do: rows(view), else: []),
      steps: steps,
      shown_ply: shown_ply,
      following?: assigns.selected == nil,
      top: if(assigns.flip, do: "white", else: "black"),
      bottom: if(assigns.flip, do: "black", else: "white")
    )
  end

  defp current_path(slug, round, board), do: "/t/#{slug}/live/#{round}/#{board}"
end
