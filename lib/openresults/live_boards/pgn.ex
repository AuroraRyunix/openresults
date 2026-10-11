defmodule OpenResults.LiveBoards.Pgn do
  @moduledoc """
  A game as PGN: the seven tag roster, the tags a tournament adds, and the
  movetext. Built from `OpenResults.LiveBoards.view/3`, so a game under a
  broadcast delay exports exactly what spectators were allowed to see.

  ## Clock times

  A move whose clock is known is followed by `{[%clk h:mm:ss]}`: the time
  the player who made it had left once it was made, in the comment format
  Lichess, chess.com and every PGN viewer since read. A move whose clock is
  not known has no comment; nothing is made up.

  A report carries both clocks as they read at that moment and which side's
  runs. The mover's clock is the figure wanted once it stands still - after
  the press, increment and all - so, in this order (`clock_times/2`):

    1. the report that brought the NEXT move, when in it the mover's clock
       stands still: it has stood still since the press that ended the move;
    2. the report that brought the move itself (`"w"` / `"b"` of the ply),
       when the mover's clock already stood still in it - a relay that
       reports on the press;
    3. for the last move of the game so far, the clocks the page itself
       shows, when they are as new as the move and the mover's is not the
       one running (a later report at the same ply: the press, a heartbeat);
    4. the report that brought the move, with the mover's clock still
       running: a relay that reports the move before the lever goes down.
       A little high and an increment short, until 1 or 3 puts it right.

  A move that arrived with several others in one report has only what 1
  gives it; only the last move of a report carries that report's clocks.

  All three read only the view: the plies a delay lets through and the
  clocks it shows. A clock time can therefore never be newer than the
  newest move in the file.
  """

  alias OpenResults.Chess

  @doc """
  `tags` is a list of `{name, value}` in the order they should appear;
  `nil` values are written as the PGN placeholder (`?`) for the seven roster
  tags and left out for the rest. The result tag and the termination marker
  come from `view`: a game still being played is `*`.
  """
  @spec build(map(), [{String.t(), String.t() | integer() | nil}]) :: String.t()
  def build(view, tags) do
    result = if view.status == "finished", do: view.result || "*", else: "*"

    tags =
      tags
      |> Enum.reject(fn {name, value} -> is_nil(value) and name not in roster() end)
      |> Enum.reject(fn {name, _} -> name in ["Result", "FEN", "SetUp"] end)

    start = view.start_fen
    standard? = start == Chess.start_fen()

    tags =
      tags ++
        [{"Result", result}] ++
        if(standard?, do: [], else: [{"SetUp", "1"}, {"FEN", start}])

    header = Enum.map_join(tags, "\n", fn {name, value} -> ~s([#{name} "#{escape(value)}"]) end)

    header <> "\n\n" <> wrap(movetext(view, start) ++ [result]) <> "\n"
  end

  @doc """
  A game nobody has sent a move for - not started yet, or never to be played
  (a forfeit) - as the tags and a bare result. The result tag is the tile's:
  a forfeit's `FF` suffix is not PGN and is dropped, and a double forfeit,
  which nobody won or drew, is `*`.
  """
  @spec build_header_only([{String.t(), String.t() | integer() | nil}]) :: String.t()
  def build_header_only(tags) do
    result =
      case tags |> List.keyfind("Result", 0, {"Result", nil}) |> elem(1) do
        value when value in ["1-0FF", "0-1FF"] -> String.replace_suffix(value, "FF", "")
        value when value in ["1-0", "0-1", "1/2-1/2"] -> value
        _none_or_double_forfeit -> "*"
      end

    tags =
      tags
      |> Enum.reject(fn {name, value} -> is_nil(value) and name not in roster() end)
      |> Enum.reject(fn {name, _} -> name == "Result" end)

    header =
      Enum.map_join(tags ++ [{"Result", result}], "\n", fn {name, value} ->
        ~s([#{name} "#{escape(value)}"])
      end)

    header <> "\n\n" <> result <> "\n"
  end

  defp roster, do: ~w(Event Site Date Round White Black Result)

  defp escape(nil), do: "?"

  # A tag value is one line: a name with a line break in it must not be able
  # to start a tag of its own.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace(~r/[\x00-\x1f\x7f]+/, " ")
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp movetext(view, start_fen) do
    {turn, number} =
      case Chess.parse_fen(start_fen) do
        {:ok, pos} -> {pos.turn, pos.fullmove}
        _error -> {:w, 1}
      end

    times = clock_times(view, turn)

    view.plies
    |> Enum.zip(times)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{ply, time}, i} ->
      white_to_move? = white?(turn, i)
      move_number = number + div(i + if(turn == :b, do: 1, else: 0), 2)
      # After a comment the move number is said again for Black, as the
      # export format has it: `1. e4 {[%clk 1:30:00]} 1... e5`.
      after_comment? = i > 0 and Enum.at(times, i - 1) != nil

      move =
        cond do
          white_to_move? -> ["#{move_number}.", ply["san"]]
          i == 0 or after_comment? -> ["#{move_number}...", ply["san"]]
          true -> [ply["san"]]
        end

      if time, do: move ++ ["{[%clk #{clk(time)}]}"], else: move
    end)
  end

  defp white?(turn, i), do: if(turn == :w, do: rem(i, 2) == 0, else: rem(i, 2) == 1)

  @doc """
  For each ply of `view`, the milliseconds its mover had left after it, or
  `nil` when that is not known. See the module's "Clock times".
  """
  @spec clock_times(map(), :w | :b) :: [non_neg_integer() | nil]
  def clock_times(view, turn \\ :w) do
    plies = view.plies
    last = length(plies) - 1
    shown = Map.get(view, :clocks) || %{}

    plies
    |> Enum.with_index()
    |> Enum.map(fn {ply, i} ->
      {key, side, name} =
        if white?(turn, i), do: {"w", :white, "white"}, else: {"b", :black, "black"}

      later = Enum.at(plies, i + 1)

      cond do
        later != nil and is_integer(later[key]) and later["r"] != name ->
          later[key]

        is_integer(ply[key]) and ply["r"] != name ->
          ply[key]

        i == last and is_integer(shown[side]) and shown[:running] != name and
          is_integer(view[:clock_at]) and is_integer(ply["at"]) and view[:clock_at] >= ply["at"] ->
          shown[side]

        is_integer(ply[key]) ->
          ply[key]

        true ->
          nil
      end
    end)
  end

  # `h:mm:ss`, whole seconds, the hours not padded: `0:03:25`, `1:30:00`.
  defp clk(ms) do
    seconds = div(max(ms, 0), 1000)
    h = div(seconds, 3600)
    m = seconds |> rem(3600) |> div(60)
    s = rem(seconds, 60)
    "#{h}:#{pad(m)}:#{pad(s)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Lines of at most 80 columns, broken between tokens.
  defp wrap(tokens) do
    {lines, current} =
      Enum.reduce(tokens, {[], ""}, fn token, {lines, line} ->
        cond do
          line == "" -> {lines, token}
          String.length(line) + 1 + String.length(token) > 80 -> {[line | lines], token}
          true -> {lines, line <> " " <> token}
        end
      end)

    [current | lines] |> Enum.reverse() |> Enum.join("\n")
  end
end
