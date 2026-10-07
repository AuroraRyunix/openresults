defmodule OpenResults.LiveBoards.Pgn do
  @moduledoc """
  A game as PGN: the seven tag roster, the tags a tournament adds, and the
  movetext. Built from `OpenResults.LiveBoards.view/3`, so a game under a
  broadcast delay exports exactly what spectators were allowed to see.
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

    view.plies
    |> Enum.with_index()
    |> Enum.flat_map(fn {ply, i} ->
      white_to_move? = if turn == :w, do: rem(i, 2) == 0, else: rem(i, 2) == 1
      move_number = number + div(i + if(turn == :b, do: 1, else: 0), 2)

      cond do
        white_to_move? -> ["#{move_number}.", ply["san"]]
        i == 0 -> ["#{move_number}...", ply["san"]]
        true -> [ply["san"]]
      end
    end)
  end

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
