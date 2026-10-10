defmodule OpenResultsWeb.ProjectorPicker do
  @moduledoc """
  The "Projector" button on the broadcast and the All boards pages, and the
  dialog behind it: which of the round's boards go on the projector, and
  whether a finished game leaves the screen by itself.

  The dialog builds an address, it does not open a session: everything the
  projector needs is in the URL (`OpenResultsWeb.ProjectorLive`), so the hall
  PC can bookmark it and come back to the same screen tomorrow.

  Not a LiveComponent: the two pages that carry it hand their `projector_*`
  events to `handle_event/3` and render `picker/1`. The round's boards are
  read when the dialog opens, never before - a spectator who never presses
  the button costs nothing.
  """

  use OpenResultsWeb, :html

  import OpenResultsWeb.LiveBoardsComponents, only: [unplayed?: 1]

  alias OpenResultsWeb.LiveBoardsData

  @doc "The assign the dialog lives in: `nil` while closed."
  def init(socket), do: assign(socket, :projector, nil)

  @doc """
  The `projector_*` events. Everything else is the page's business. Opening
  reads `payload`, `slug` and `round` from the page's assigns.
  """
  def handle_event("projector_open", _params, socket) do
    %{payload: payload, slug: slug, round: round} = socket.assigns

    boards =
      if payload && round do
        for tile <- LiveBoardsData.tiles(payload, slug, round, plies: false) do
          %{
            board: tile.board,
            label: tile.label,
            white: tile.white && tile.white.name,
            black: tile.black && tile.black.name,
            unplayed?: unplayed?(tile)
          }
        end
      else
        []
      end

    assign(socket, :projector, %{
      boards: boards,
      selected: MapSet.new(boards, & &1.board),
      auto: true,
      form: to_form(%{}, as: :projector)
    })
  end

  def handle_event("projector_close", _params, socket), do: assign(socket, :projector, nil)

  def handle_event("projector_all", _params, %{assigns: %{projector: %{} = p}} = socket),
    do: assign(socket, :projector, %{p | selected: MapSet.new(p.boards, & &1.board)})

  def handle_event("projector_none", _params, %{assigns: %{projector: %{} = p}} = socket),
    do: assign(socket, :projector, %{p | selected: MapSet.new()})

  def handle_event("projector_change", params, %{assigns: %{projector: %{} = p}} = socket) do
    form = Map.get(params, "projector", %{})
    known = MapSet.new(p.boards, & &1.board)

    selected =
      form
      |> Map.get("boards", [])
      |> List.wrap()
      |> Enum.flat_map(fn value ->
        case Integer.parse(to_string(value)) do
          {n, ""} -> if MapSet.member?(known, n), do: [n], else: []
          _junk -> []
        end
      end)
      |> MapSet.new()

    assign(socket, :projector, %{p | selected: selected, auto: Map.get(form, "auto") == "true"})
  end

  def handle_event(_event, _params, socket), do: socket

  @doc """
  The projector's address for a choice: `?boards=` only when the choice is
  not the whole round (no list means every board, which is also what a round
  that gains a board later should show), `auto=1|0` always, and the piece set
  in use, so the projector draws what the person choosing was looking at.
  """
  def url(slug, round, picker, pieces) do
    all = Enum.map(picker.boards, & &1.board)
    chosen = Enum.filter(all, &MapSet.member?(picker.selected, &1))

    # Integers and commas only, so the list is written out as it is read -
    # `boards=1,3,5`, not `boards=1%2C3%2C5` - on a bookmark someone may edit.
    boards = if chosen != all, do: ["boards=" <> Enum.join(chosen, ",")], else: []

    rest =
      URI.encode_query([auto: if(picker.auto, do: "1", else: "0"), pieces: pieces], :rfc3986)

    "/t/#{slug}/live/#{round}/projector?" <> Enum.join(boards ++ [rest], "&")
  end

  @doc "The button that opens the dialog."
  def button(assigns) do
    ~H"""
    <button
      type="button"
      id="projector-button"
      class="lb-switch-opt lb-projector-btn"
      phx-click="projector_open"
      aria-haspopup="dialog"
    >
      <svg viewBox="0 0 24 24" aria-hidden="true" class="lb-icon">
        <path d="M3 5h18v11H3zM8 20h8M12 16v4" />
      </svg>
      {gettext("Projector")}
    </button>
    """
  end

  attr :picker, :map, default: nil
  attr :slug, :string, required: true
  attr :round, :integer, default: nil
  attr :pieces, :string, required: true

  @doc "The dialog, while it is open."
  def picker(assigns) do
    ~H"""
    <div
      :if={@picker && @round}
      id="projector-picker"
      class="lb-picker-backdrop"
      phx-window-keydown="projector_close"
      phx-key="Escape"
    >
      <div
        class="lb-picker"
        role="dialog"
        aria-modal="true"
        aria-labelledby="projector-picker-title"
        phx-click-away="projector_close"
        phx-mounted={JS.focus_first()}
      >
        <header class="lb-picker-head">
          <h2 id="projector-picker-title">{gettext("Projector view")}</h2>
          <button
            type="button"
            id="projector-close"
            class="lb-icon-btn"
            phx-click="projector_close"
            aria-label={gettext("Close")}
            title={gettext("Close")}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true" class="lb-icon">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </header>
        <p class="lb-picker-lead">
          {gettext(
            "Choose the boards to show. The projector opens in a new tab with just these games, as large as the screen allows - bookmark it on the hall PC."
          )}
        </p>
        <.form for={@picker.form} id="projector-form" phx-change="projector_change">
          <div class="lb-picker-quick">
            <span>
              {gettext("%{chosen} of %{count} boards",
                chosen: MapSet.size(@picker.selected),
                count: length(@picker.boards)
              )}
            </span>
            <button
              type="button"
              id="projector-all"
              class="lb-btn lb-btn-text"
              phx-click="projector_all"
            >
              {gettext("Select all")}
            </button>
            <button
              type="button"
              id="projector-none"
              class="lb-btn lb-btn-text"
              phx-click="projector_none"
            >
              {gettext("Select none")}
            </button>
          </div>
          <input type="hidden" name="projector[boards][]" value="" />
          <ul id="projector-boards" class="lb-picker-list">
            <li :for={b <- @picker.boards}>
              <label class="lb-picker-row">
                <input
                  type="checkbox"
                  id={"projector-board-#{b.board}"}
                  name="projector[boards][]"
                  value={b.board}
                  checked={MapSet.member?(@picker.selected, b.board)}
                />
                <span class="lb-picker-bd">{b.label}</span>
                <span class="lb-picker-names">
                  <span>{b.white || "-"}</span>
                  <span class="lb-picker-vs" aria-hidden="true">-</span>
                  <span>{b.black || "-"}</span>
                </span>
                <span :if={b.unplayed?} class="lb-ff">FF</span>
              </label>
            </li>
          </ul>
          <input type="hidden" name="projector[auto]" value="false" />
          <label class="lb-picker-auto">
            <input
              type="checkbox"
              id="projector-auto"
              name="projector[auto]"
              value="true"
              checked={@picker.auto}
            />
            <span>
              {gettext("Remove finished games automatically")}
              <small>
                {gettext(
                  "A finished game shows its result for half a minute, then makes room for the others. Forfeits are left out."
                )}
              </small>
            </span>
          </label>
        </.form>
        <footer class="lb-picker-foot">
          <a
            :if={MapSet.size(@picker.selected) > 0}
            id="projector-open"
            class="lb-btn lb-btn-text lb-btn-primary"
            href={url(@slug, @round, @picker, @pieces)}
            target="_blank"
            rel="noopener"
            phx-click="projector_close"
          >
            {gettext("Open the projector view")}
          </a>
          <span :if={MapSet.size(@picker.selected) == 0} id="projector-pick-one" class="lb-quiet-line">
            {gettext("Choose at least one board.")}
          </span>
        </footer>
      </div>
    </div>
    """
  end
end
