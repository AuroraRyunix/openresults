defmodule OpenResults.LiveBoards.PgnReader do
  @moduledoc """
  Reads games out of PGN text, for the simulator (`mix openresults.live_sim`)
  and nothing else - it is not a general PGN parser and does not check that
  a move is legal (the ingest does).

  Understands the tag pairs, move numbers, `{brace}` and `;line` comments,
  `(variations)`, numeric annotation glyphs and the result token. A
  `[%clk h:mm:ss]` command inside a comment is kept: the clock after the move
  it follows.
  """

  @type game :: %{
          headers: %{String.t() => String.t()},
          moves: [String.t()],
          clocks: [non_neg_integer() | nil],
          result: String.t()
        }

  @results ["1-0", "0-1", "1/2-1/2", "*"]

  @doc "Every game in `text`, in order. Chunks with no moves are skipped."
  @spec parse(String.t()) :: [game()]
  def parse(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/\A\xEF\xBB\xBF/, "")
    |> String.split(~r/\n\s*\n(?=\[)/)
    |> Enum.map(&game/1)
    |> Enum.reject(&(&1.moves == []))
  end

  defp game(chunk) do
    lines = String.split(chunk, "\n")

    {tag_lines, rest} =
      Enum.split_while(lines, &(String.trim(&1) == "" or String.starts_with?(&1, "[")))

    headers =
      for line <- tag_lines,
          [_, name, value] <- [Regex.run(~r/^\s*\[(\w+)\s+"(.*)"\]\s*$/, line)],
          into: %{},
          do: {name, value}

    {moves, clocks, result} = movetext(Enum.join(rest, "\n"))
    %{headers: headers, moves: moves, clocks: clocks, result: result || headers["Result"] || "*"}
  end

  @token ~r/\{[^}]*\}|;[^\n]*|\(|\)|[^\s(){};]+/

  defp movetext(text) do
    @token
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.reduce({0, [], nil}, &token/2)
    |> then(fn {_depth, acc, result} ->
      moves = acc |> Enum.reverse() |> Enum.map(&elem(&1, 0))
      clocks = acc |> Enum.reverse() |> Enum.map(&elem(&1, 1))
      {moves, clocks, result}
    end)
  end

  # `{depth, [{san, clock_ms}] newest first, result}`
  defp token("(", {depth, acc, result}), do: {depth + 1, acc, result}
  defp token(")", {depth, acc, result}), do: {max(depth - 1, 0), acc, result}
  defp token(_ignored, {depth, acc, result}) when depth > 0, do: {depth, acc, result}
  defp token("$" <> _glyph, state), do: state
  defp token(";" <> _comment, state), do: state
  defp token(word, {depth, acc, _result}) when word in @results, do: {depth, acc, word}

  defp token("{" <> comment, {depth, [{san, nil} | rest], result}) do
    case Regex.run(~r/\[%clk\s+(\d+):(\d+):(\d+)/, comment) do
      [_, h, m, s] ->
        ms =
          ((String.to_integer(h) * 60 + String.to_integer(m)) * 60 + String.to_integer(s)) * 1000

        {depth, [{san, ms} | rest], result}

      _no_clock ->
        {depth, [{san, nil} | rest], result}
    end
  end

  defp token("{" <> _comment, state), do: state

  # A move, possibly glued to its number ("1.e4"), or a number on its own.
  defp token(word, {depth, acc, result}) do
    case word |> String.replace(~r/^\d+\.+/, "") |> String.replace(~r/[!?]+$/, "") do
      "" -> {depth, acc, result}
      move -> {depth, [{move, nil} | acc], result}
    end
  end
end
