defmodule OpenResultsWeb.LiveBoardsComponents do
  @moduledoc """
  The pieces the live-board pages and the hall display share: the board as
  SVG, a clock that counts on its own, a tile for one game, and the page
  shell the two live pages sit in.

  ## The board

  Server-rendered SVG from a FEN, never from a script: a position is a few
  hundred bytes of markup, the page works while the socket reconnects, and a
  tile that has not changed costs nothing to keep. The pieces are drawn once
  per page in `piece_sprite/1` and placed with `<use>`, so a round of sixty
  boards does not repeat the shapes sixty times.

  The pieces are this project's own drawings - plain geometric silhouettes -
  and carry no third-party licence. See `NOTICE`.

  ## The clocks

  The server sends what a clock reads at the moment it renders and whether it
  is running; the browser counts it down (`.LiveClock`, below) and is
  corrected by the next update. Nothing here asks the server what time it is
  once a second.
  """

  use OpenResultsWeb, :html

  alias OpenResults.Chess
  alias OpenResultsWeb.LiveBoardsData

  # --- the pieces --------------------------------------------------------------

  @doc """
  The six shapes in both colours, as `<symbol>`s. Once per page; everything
  else refers to them by id (`lb-wk`, `lb-bp`...).
  """
  def piece_sprite(assigns) do
    ~H"""
    <svg class="lb-sprite" width="0" height="0" aria-hidden="true" focusable="false">
      <defs>
        <symbol :for={colour <- ["w", "b"]} id={"lb-#{colour}k"} viewBox="0 0 45 45">
          <path d="M22.5 5.5v7M19 9h7" fill="none" />
          <path d="M22.5 13c-6.500 0-11.500 4.600-11.500 10.700 0 3.600 1.700 6 4 7.300L14 37h17l-1-6c2.300-1.300 4-3.700 4-7.300C34 17.600 29 13 22.500 13z" />
          <path d="M11.500 37h22v3.500h-22z" />
          <path d="M16 26.500h13" fill="none" />
        </symbol>
        <symbol :for={colour <- ["w", "b"]} id={"lb-#{colour}q"} viewBox="0 0 45 45">
          <path d="M9.500 37 7.500 16.500l7.700 8.500L17.500 13l5 11.500L27.500 13l2.300 12 7.700-8.500L35.500 37z" />
          <path d="M9 37h27v3.500H9z" />
          <circle cx="7.500" cy="14" r="2.400" />
          <circle cx="15.500" cy="10" r="2.400" />
          <circle cx="22.500" cy="8.500" r="2.400" />
          <circle cx="29.500" cy="10" r="2.400" />
          <circle cx="37.500" cy="14" r="2.400" />
        </symbol>
        <symbol :for={colour <- ["w", "b"]} id={"lb-#{colour}r"} viewBox="0 0 45 45">
          <path d="M11.500 18.500V10h5v3h4v-3h4v3h4v-3h5v8.500z" />
          <path d="M14.500 18.500h16V33h-16z" />
          <path d="M11.500 33h22v5.500h-22z" />
          <path d="M11.500 38.500h22" fill="none" />
        </symbol>
        <symbol :for={colour <- ["w", "b"]} id={"lb-#{colour}b"} viewBox="0 0 45 45">
          <path d="M22.500 9c-3.200 3-7.500 7.200-7.500 13 0 3 1.500 5 3 6.200-2.100 1.300-4 3.600-4 9.300h17c0-5.700-1.900-8-4-9.300 1.500-1.200 3-3.200 3-6.200 0-5.800-4.300-10-7.500-13z" />
          <circle cx="22.500" cy="7" r="2.600" />
          <path d="M22.500 15.500v6M19.500 18.500h6" fill="none" />
          <path d="M11.500 37.500h22V40h-22z" />
        </symbol>
        <symbol :for={colour <- ["w", "b"]} id={"lb-#{colour}n"} viewBox="0 0 45 45">
          <path d="M11.500 38.500c0-8.500 2.300-13.500 7.800-16.800L14 20.300 9.500 20 9 16.300l5.700-6.700.5-5 4.500 4c10 .3 17 8.300 16 25.900z" />
          <circle cx="17" cy="14" r="1.200" class="lb-eye" />
          <path d="M11.500 38.500h24" fill="none" />
        </symbol>
        <symbol :for={colour <- ["w", "b"]} id={"lb-#{colour}p"} viewBox="0 0 45 45">
          <circle cx="22.500" cy="13" r="5" />
          <path d="M22.500 18.500c-3.300 0-5.700 2.200-5.700 5 0 1.600.9 3 2.300 3.800-3.600 1.400-5.600 4.700-5.600 8.700h18c0-4-2-7.300-5.600-8.700 1.400-.8 2.300-2.200 2.300-3.800 0-2.800-2.400-5-5.700-5z" />
          <path d="M11.500 36h22v3.500h-22z" />
        </symbol>
      </defs>
    </svg>
    """
  end

  # --- the board ---------------------------------------------------------------

  attr :fen, :string, required: true
  attr :last, :any, default: nil, doc: "`{from, to}` square indices to highlight, or nil"
  attr :flip, :boolean, default: false
  attr :coords, :boolean, default: false
  attr :id, :string, default: nil
  attr :label, :string, required: true, doc: "what a screen reader says about the picture"
  attr :class, :string, default: nil

  def board_svg(assigns) do
    pieces =
      case Chess.parse_fen(assigns.fen) do
        {:ok, position} -> Chess.pieces(position)
        {:error, _message} -> []
      end

    assigns =
      assigns
      |> assign(
        :pieces,
        for({i, {colour, kind}} <- pieces, do: {square(i, assigns.flip), "#{colour}#{kind}"})
      )
      |> assign(:dark, dark_squares())
      |> assign(:marked, marked(assigns.last, assigns.flip))
      |> assign(:viewbox, if(assigns.coords, do: "-0.45 -0.15 8.6 8.6", else: "0 0 8 8"))

    ~H"""
    <svg
      id={@id}
      class={["lb-board", @class]}
      viewBox={@viewbox}
      role="img"
      aria-label={@label}
      preserveAspectRatio="xMidYMid meet"
    >
      <rect x="0" y="0" width="8" height="8" class="lb-sq-light" />
      <rect :for={{x, y} <- @dark} x={x} y={y} width="1" height="1" class="lb-sq-dark" />
      <rect :for={{x, y} <- @marked} x={x} y={y} width="1" height="1" class="lb-sq-last" />
      <g :if={@coords} class="lb-coords" aria-hidden="true">
        <text :for={n <- 0..7} x={n + 0.5} y="8.12" text-anchor="middle">
          {file_name(n, @flip)}
        </text>
        <text :for={n <- 0..7} x="-0.2" y={n + 0.64} text-anchor="middle">
          {rank_name(n, @flip)}
        </text>
      </g>
      <use
        :for={{{x, y}, piece} <- @pieces}
        href={"#lb-" <> piece}
        x={x}
        y={y}
        width="1"
        height="1"
        class={["lb-pc", if(String.starts_with?(piece, "w"), do: "lb-pc-w", else: "lb-pc-b")]}
      />
    </svg>
    """
  end

  # (file, row) of square index `i` on screen. Row 0 is the top.
  defp square(i, false), do: {rem(i, 8), div(i, 8)}
  defp square(i, true), do: {7 - rem(i, 8), 7 - div(i, 8)}

  defp marked(nil, _flip), do: []
  defp marked({from, to}, flip), do: [square(from, flip), square(to, flip)]

  defp dark_squares, do: for(y <- 0..7, x <- 0..7, rem(x + y, 2) == 1, do: {x, y})

  defp file_name(n, flip), do: <<?a + if(flip, do: 7 - n, else: n)>>
  defp rank_name(n, flip), do: to_string(if(flip, do: n + 1, else: 8 - n))

  # --- the clock ---------------------------------------------------------------

  attr :id, :string, required: true
  attr :ms, :any, required: true, doc: "what it reads now, in ms, or nil when unknown"
  attr :running, :boolean, default: false
  attr :class, :string, default: nil

  def clock(assigns) do
    ~H"""
    <span
      id={@id}
      class={["lb-clock", @running && "is-running", @class]}
      phx-hook=".LiveClock"
      data-ms={@ms}
      data-running={to_string(@running and is_integer(@ms))}
    >
      {format_clock(@ms)}
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LiveClock">
      const format = (ms) => {
        const total = Math.floor(Math.max(0, ms) / 1000)
        const h = Math.floor(total / 3600)
        const m = Math.floor((total % 3600) / 60)
        const s = String(total % 60).padStart(2, "0")
        return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`
      }

      export default {
        mounted() { this.sync() },
        updated() { this.sync() },
        destroyed() { this.stop() },
        stop() { if (this.timer) { clearInterval(this.timer); this.timer = null } },
        sync() {
          this.stop()
          this.base = Number(this.el.dataset.ms)
          if (!Number.isFinite(this.base)) return
          this.from = performance.now()
          this.running = this.el.dataset.running === "true"
          this.paint()
          if (this.running) this.timer = setInterval(() => this.paint(), 200)
        },
        paint() {
          const left = Math.max(0, this.base - (this.running ? performance.now() - this.from : 0))
          const text = format(left)
          if (this.el.textContent !== text) this.el.textContent = text
          this.el.classList.toggle("is-low", this.running && left < 30000)
        }
      }
    </script>
    """
  end

  @doc "`7:05`, or `1:02:03` from an hour; `-:--` when unknown. The browser formats the same way."
  def format_clock(ms) when is_integer(ms) do
    total = div(max(ms, 0), 1000)
    {h, m, s} = {div(total, 3600), div(rem(total, 3600), 60), rem(total, 60)}
    secs = String.pad_leading(Integer.to_string(s), 2, "0")

    if h > 0,
      do: "#{h}:#{String.pad_leading(Integer.to_string(m), 2, "0")}:#{secs}",
      else: "#{m}:#{secs}"
  end

  def format_clock(_unknown), do: "-:--"

  # --- a game, as a tile -------------------------------------------------------

  attr :tile, :map, required: true
  attr :slug, :string, required: true
  attr :link?, :boolean, default: true
  attr :class, :string, default: nil

  def tile(assigns) do
    tile = assigns.tile
    view = tile.view
    result = LiveBoardsData.result(tile)
    status = status(tile)

    assigns =
      assigns
      |> assign(:fen, if(view, do: view.fen, else: Chess.start_fen()))
      |> assign(:last, view && view.last)
      |> assign(:clocks, view && view.clocks)
      |> assign(:result, result)
      |> assign(:status, status)
      |> assign(:last_move, view && last_move_label(view))

    ~H"""
    <article id={@tile.id} class={["lb-tile", "lb-status-#{@status}", @class]}>
      <header class="lb-tile-head">
        <span class="lb-tile-board">{gettext("Bd %{board}", board: @tile.label)}</span>
        <span class="lb-badge">{status_label(@status, @result)}</span>
      </header>
      <.player_line tile={@tile} colour="black" clocks={@clocks} />
      <.link
        :if={@link?}
        navigate={~p"/t/#{@slug}/live/#{@tile.round}/#{@tile.board}"}
        class="lb-tile-board-link"
        aria-label={tile_label(@tile)}
      >
        <.board_svg fen={@fen} last={@last} label={tile_label(@tile)} />
      </.link>
      <div :if={not @link?} class="lb-tile-board-link">
        <.board_svg fen={@fen} last={@last} label={tile_label(@tile)} />
      </div>
      <.player_line tile={@tile} colour="white" clocks={@clocks} />
      <footer class="lb-tile-foot">
        <span :if={@last_move} class="lb-last-move">{@last_move}</span>
        <span :if={@result} class="lb-result">
          {elem(@result, 0)}<span :if={elem(@result, 1)} class="lb-provisional"> *</span>
        </span>
      </footer>
    </article>
    """
  end

  attr :tile, :map, required: true
  attr :colour, :string, required: true
  attr :clocks, :any, default: nil

  def player_line(assigns) do
    person = if assigns.colour == "white", do: assigns.tile.white, else: assigns.tile.black
    ms = assigns.clocks && Map.get(assigns.clocks, String.to_existing_atom(assigns.colour))
    running = assigns.clocks && assigns.clocks.running == assigns.colour

    assigns =
      assigns
      |> assign(:person, person)
      |> assign(:ms, ms)
      |> assign(:running, running || false)
      |> assign(:has_clock, assigns.clocks != nil and ms != nil)

    ~H"""
    <div class={["lb-player", "lb-player-#{@colour}", @running && "is-to-move"]}>
      <span class={["lb-dot", "lb-dot-#{@colour}"]} aria-hidden="true"></span>
      <span class="lb-name">
        <span :if={@person && @person.title} class="lb-title">{@person.title}</span>
        <span class="lb-person">{(@person && @person.name) || "-"}</span>
        <span :if={@person && @person.rating} class="lb-rating">{@person.rating}</span>
      </span>
      <.clock
        :if={@has_clock}
        id={"#{@tile.id}-clock-#{@colour}"}
        ms={@ms}
        running={@running}
      />
    </div>
    """
  end

  @doc false
  def tile_label(tile) do
    gettext("Board %{board}: %{white} against %{black}",
      board: tile.label,
      white: (tile.white && tile.white.name) || "-",
      black: (tile.black && tile.black.name) || "-"
    )
  end

  @doc "`:live`, `:finished` or `:waiting` - whether anything is on the board."
  def status(%{view: nil}), do: :waiting
  def status(%{view: %{status: "finished"}}), do: :finished
  def status(%{view: %{ply: 0}}), do: :waiting
  def status(_tile), do: :live

  @doc false
  def status_label(:live, _result), do: gettext("Live")
  def status_label(:waiting, _result), do: gettext("Not started")

  def status_label(:finished, _result), do: gettext("Game over")

  # "12. Nf3" or "12... Nf6": the move number from the position after it.
  @doc false
  def last_move_label(%{last_san: nil}), do: nil

  def last_move_label(%{last_san: san, fen: fen}) do
    case String.split(fen) do
      [_placement, "b" | rest] -> "#{fullmove(rest)}. #{san}"
      [_placement, "w" | rest] -> "#{max(fullmove(rest) - 1, 1)}... #{san}"
      _other -> san
    end
  end

  defp fullmove([_castling, _ep, _half, full]) do
    case Integer.parse(full) do
      {n, ""} -> n
      _bad -> 1
    end
  end

  defp fullmove(_other), do: 1

  # --- the page shell ----------------------------------------------------------

  attr :locale, :string, required: true
  attr :path, :string, required: true, doc: "this page's own path, for the language links"
  attr :slug, :string, required: true
  attr :title, :string, required: true, doc: "the tournament's name"
  slot :inner_block, required: true
  slot :foot

  @doc """
  The site's masthead (brand, languages, theme) and footer around a live
  page. The same classes the rest of the site uses, so the page looks like
  it belongs; the theme picker is the same control, driven by a hook instead
  of the inline script the static pages carry.
  """
  def shell(assigns) do
    ~H"""
    <a class="skip-link" href="#main">{gettext("Skip to content")}</a>
    <div class="page lb-page">
      <header class="masthead-bar">
        <a class="brand" href={~p"/"}>
          <.logo /> OpenResults
        </a>
        <div class="masthead-tools">
          <nav class="lang-picker" aria-label={gettext("Language")}>
            <a
              :for={{code, name} <- OpenResultsWeb.Locale.locales()}
              href={@path <> "?" <> URI.encode_query([{OpenResultsWeb.Locale.param(), code}])}
              hreflang={code}
              lang={code}
              title={name}
              class={["lang-opt", code == @locale && "is-current"]}
              aria-current={code == @locale && "true"}
            >
              <span aria-hidden="true">{String.upcase(code)}</span>
              <span class="visually-hidden">{name}</span>
            </a>
          </nav>
          <.theme_picker />
        </div>
      </header>
      <main id="main" tabindex="-1" class="lb-main">
        <p class="admin-crumbs lb-crumbs">
          <a href={~p"/t/#{@slug}"}>{@title}</a>
        </p>
        {render_slot(@inner_block)}
      </main>
      <footer class="site-foot">
        <span>{gettext("Published by the arbiter. Results are theirs, not this site's.")}</span>
        <span class="spacer"></span>
        {render_slot(@foot)}
        <a class="terms-link" href={~p"/terms"}>{gettext("Terms and privacy")}</a>
      </footer>
    </div>
    """
  end

  defp theme_picker(assigns) do
    ~H"""
    <details class="theme-picker" id="lb-theme-picker" phx-hook=".ThemePicker" phx-update="ignore">
      <summary
        class="theme-picker-trigger"
        title={gettext("Colour theme")}
        aria-label={gettext("Colour theme")}
      >
        <span class="theme-picker-swatch" aria-hidden="true"></span> {gettext("Theme")}
      </summary>
      <div class="theme-picker-panel" role="group" aria-label={gettext("Colour theme")}>
        <button
          :for={
            {key, label} <- [
              {"system", gettext("Match device")},
              {"paper", gettext("Paper")},
              {"night", gettext("Night")},
              {"board", gettext("Board")},
              {"slate", gettext("Slate")},
              {"contrast", gettext("High contrast")}
            ]
          }
          type="button"
          class="theme-picker-item"
          data-theme-opt={key}
        >
          <span class={"theme-dot theme-dot-#{key}"} aria-hidden="true"></span>
          {label}
        </button>
      </div>
    </details>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ThemePicker">
      const KEY = "openresults:theme"

      export default {
        mounted() {
          const root = document.documentElement
          const trigger = this.el.querySelector("summary")

          const mark = () => {
            const source = root.getAttribute("data-theme-source")
            const current = source === "system" ? "system"
              : source === "default" ? "paper" : root.getAttribute("data-theme")
            this.el.querySelectorAll("[data-theme-opt]").forEach((o) => {
              o.setAttribute("aria-pressed", String(o.dataset.themeOpt === current))
            })
          }
          mark()

          this.el.addEventListener("click", (e) => {
            const button = e.target.closest("[data-theme-opt]")
            if (!button) return
            const value = button.dataset.themeOpt
            try { localStorage.setItem(KEY, value) } catch (_) {}
            if (value === "system") {
              root.removeAttribute("data-theme")
              root.setAttribute("data-theme-source", "system")
            } else {
              root.setAttribute("data-theme", value)
              root.setAttribute("data-theme-source", "user")
            }
            mark()
            this.el.removeAttribute("open")
            if (trigger) trigger.focus()
          })

          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Escape" && this.el.open) {
              this.el.removeAttribute("open")
              if (trigger) trigger.focus()
            }
          })
        }
      }
    </script>
    """
  end
end
