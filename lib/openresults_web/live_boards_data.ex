defmodule OpenResultsWeb.LiveBoardsData do
  @moduledoc """
  What the live-board pages show: a published round's boards (the snapshot's
  say-so: who sits where) joined with the live game on each
  (`OpenResults.LiveBoards`'s say-so: what is being played).

  ## What a spectator may see

  A live game is shown only if its board is in the published snapshot. A round
  the arbiter has not published, a hidden board, and every game of a
  tournament whose pairings are switched off (`display.pairings`) simply have
  no tile, whatever the relay has reported - the relay may know a pairing the
  arbiter has not released.

  Names, titles, ratings and federations follow the same ticks as every other
  public page. A result follows the round's own rule: where the round's
  results are not public (`rounds[].results_public: false`), neither the
  published result nor the relay's suggestion is shown, only that the game is
  over.
  """

  alias OpenResults.LiveBoards
  alias OpenResultsWeb.Tournament

  @doc "Whether this tournament's pairings - and so its live boards - are public."
  def public?(payload), do: Tournament.show?(payload, "pairings")

  @doc "The published rounds that have boards, in order."
  def rounds(payload) do
    if public?(payload) do
      payload |> Tournament.rounds() |> Enum.filter(&(Tournament.boards(&1) != []))
    else
      []
    end
  end

  @doc "The newest published round with boards, or `nil`."
  def latest_round(payload), do: payload |> rounds() |> List.last()

  @doc """
  The tiles of round `number`: one per published board, in board order, each
  with its `:view` (`nil` while nothing has been reported).

  Options: `:now_ms`, for tests; `:plies` (default `true`), which `false`
  turns into a read that leaves the move lists out when no delay is set - the
  views then carry `plies: []` but everything a tile is drawn from; `:only`,
  one board number, which reads that game alone (`tile/5` sets it).
  """
  def tiles(payload, slug, number, opts \\ []) do
    case Tournament.round(payload, number) do
      nil -> []
      round -> build(payload, slug, round, opts)
    end
  end

  defp build(payload, slug, round, opts) do
    if public?(payload) do
      number = Map.get(round, "number")
      now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.os_time(:millisecond) end)
      delay_ms = :timer.minutes(LiveBoards.delay_minutes(slug))
      # Move lists are read only when they are used: always for one game's own
      # page, and for a tile only while a delay makes the arrival time of
      # each move matter.
      plies? = Keyword.get(opts, :plies, true) or delay_ms > 0
      games = games(slug, number, Keyword.get(opts, :only), plies?)
      players = Tournament.players_by_no(payload)
      show = show(payload)
      results? = Tournament.results_public?(round)

      in_match =
        if Tournament.team_event?(payload), do: Tournament.board_matches(round), else: %{}

      for board <- Tournament.boards(round), is_integer(Map.get(board, "board")) do
        no = Map.get(board, "board")
        game = Map.get(games, no)
        view = game && LiveBoards.view(game, delay_ms, now_ms)

        %{
          id: "live-#{number}-#{no}",
          round: number,
          board: no,
          label: label(board, Map.get(in_match, no)),
          white: person(players, Map.get(board, "white"), show),
          black: person(players, Map.get(board, "black"), show),
          official: if(results?, do: string(board, "result")),
          results?: results?,
          view: view,
          signature: signature(view)
        }
      end
    else
      []
    end
  end

  defp label(board, nil), do: Tournament.board_label(board)
  defp label(_board, %{match: match, k: k}), do: "#{match["number"]}/#{k}"

  # One round's games by board number - or one game's, for a refresh that
  # concerns one board.
  defp games(slug, number, nil, plies?),
    do: Map.new(LiveBoards.games_for_round(slug, number, plies: plies?), &{&1.board, &1})

  defp games(slug, number, board, _plies?) do
    case LiveBoards.get_game(slug, number, board) do
      nil -> %{}
      game -> %{game.board => game}
    end
  end

  @doc """
  One tile, or `nil` when the board is not published. Options as `tiles/4`.
  """
  def tile(payload, slug, number, board, opts \\ []) do
    payload
    |> tiles(slug, number, Keyword.put(opts, :only, board))
    |> Enum.find(&(&1.board == board))
  end

  # What changes what a tile looks like, apart from the clocks, which count on
  # in the browser.
  defp signature(nil), do: nil

  defp signature(view),
    do: {view.ply, view.fen, view.status, view.result, view.clocks.running}

  @doc """
  The result to print on a tile: the published one, else - once the game is
  over and the round's results are public - the relay's suggestion, marked
  `provisional`.
  """
  def result(%{official: official}) when is_binary(official), do: {official, false}

  def result(%{results?: true, view: %{status: "finished", result: result}})
      when is_binary(result) and result != "*",
      do: {result, true}

  def result(_tile), do: nil

  @doc "Whether the game is on the boards right now."
  def live?(%{view: %{status: "live"}}), do: true
  def live?(_tile), do: false

  defp show(payload) do
    Map.new(~w(rating title federation), &{String.to_atom(&1), Tournament.show?(payload, &1)})
  end

  defp person(_players, nil, _show), do: nil

  defp person(players, no, show) do
    player = Map.get(players, no, %{})

    %{
      no: no,
      name: string(player, "name") || "#" <> to_string(no),
      title: if(show.title, do: string(player, "title")),
      rating: if(show.rating, do: positive(Map.get(player, "rating"))),
      federation: if(show.federation, do: string(player, "federation"))
    }
  end

  @doc "The PGN tags for a tile's game, honouring the same ticks as the page."
  def pgn_tags(payload, tile) do
    round = Tournament.round(payload, tile.round) || %{}
    players = Tournament.players_by_no(payload)
    info = Tournament.info(payload)
    show = show(payload)
    result = result(tile)

    side = fn colour, person ->
      raw = person && Map.get(players, person.no, %{})

      [
        {colour, person && person.name},
        {"#{colour}Title", person && person.title},
        {"#{colour}Elo", person && person.rating},
        {"#{colour}FideId", if(person && show.federation, do: raw && Map.get(raw, "fide_id"))}
      ]
    end

    date = string(round, "date") || string(info, "start_date")
    date = if Tournament.show?(payload, "dates"), do: date
    city = if Tournament.show?(payload, "city"), do: string(info, "city")

    [
      {"Event", Tournament.name(payload)},
      {"Site", city},
      {"Date", date && String.replace(date, "-", ".")},
      {"Round", "#{tile.round}.#{tile.board}"}
    ] ++
      side.("White", tile.white) ++
      side.("Black", tile.black) ++
      [{"Result", result && elem(result, 0)}]
  end

  defp string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  defp string(_other, _key), do: nil

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_other), do: nil
end
