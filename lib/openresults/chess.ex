defmodule OpenResults.Chess do
  @moduledoc """
  Just enough chess to check what a hall relay sends: FEN in and out, the
  legal moves of a position, SAN read and written, and what a position is
  (checkmate, stalemate, dead).

  No dependency: no maintained pure-Elixir chess library was in the tree, and
  a legality checker is small enough to own and to prove with perft - see
  `test/openresults/chess_test.exs`, which counts the nodes of the standard
  test positions against the published numbers.

  ## Representation

  A position is a map: `board` (a 64-tuple, index 0 = a8 through 63 = h1, each
  entry `nil` or `{colour, kind}` with colour `:w | :b` and kind
  `:p | :n | :b | :r | :q | :k`), `turn`, `castling` (the subset of
  `~w(K Q k q)` still available), `ep` (the square a pawn may capture onto, or
  `nil`), `halfmove` and `fullmove`. FEN's order, so a FEN string and the
  board tuple read the same way.

  A move is `%{from, to, kind, piece, capture, promo}` where `kind` is one of
  `:normal | :double | :ep | :castle_k | :castle_q`.
  """

  @start_fen "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

  @knight [{1, 2}, {2, 1}, {2, -1}, {1, -2}, {-1, -2}, {-2, -1}, {-2, 1}, {-1, 2}]
  @king [{1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}]
  @rook [{1, 0}, {-1, 0}, {0, 1}, {0, -1}]
  @bishop [{1, 1}, {1, -1}, {-1, 1}, {-1, -1}]

  @type colour :: :w | :b
  @type position :: map()
  @type move :: map()

  @doc "The standard starting position, as FEN."
  def start_fen, do: @start_fen

  @doc "The starting position."
  def start do
    {:ok, pos} = parse_fen(@start_fen)
    pos
  end

  # --- FEN ---------------------------------------------------------------------

  @doc """
  Reads a FEN. The two move counters may be left off (a relay often does).
  Refuses anything that is not a position with exactly one king a side and no
  pawn on a back rank.
  """
  @spec parse_fen(term()) :: {:ok, position()} | {:error, String.t()}
  def parse_fen(fen) when is_binary(fen) do
    with {:ok, [placement, turn, castling, ep, half, full]} <- fields(fen),
         {:ok, board} <- placement(placement),
         {:ok, turn} <- turn(turn),
         {:ok, castling} <- castling(castling),
         {:ok, ep} <- ep_square(ep),
         {:ok, half} <- counter(half, 0),
         {:ok, full} <- counter(full, 1),
         :ok <- sane(board) do
      {:ok,
       %{board: board, turn: turn, castling: castling, ep: ep, halfmove: half, fullmove: full}}
    end
  end

  def parse_fen(_not_text), do: {:error, "a FEN must be a string"}

  defp fields(fen) do
    case String.split(fen) do
      [_p, _t, _c, _e] = four -> {:ok, four ++ ["0", "1"]}
      [_p, _t, _c, _e, _h, _f] = six -> {:ok, six}
      _other -> {:error, "a FEN has four or six fields"}
    end
  end

  defp placement(text) do
    rows = String.split(text, "/")

    if length(rows) == 8 do
      rows
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case row_squares(String.to_charlist(row), []) do
          {:ok, squares} when length(squares) == 8 -> {:cont, {:ok, [squares | acc]}}
          _bad -> {:halt, {:error, "the FEN's piece placement is malformed"}}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, reversed |> Enum.reverse() |> List.flatten() |> List.to_tuple()}
        error -> error
      end
    else
      {:error, "the FEN's piece placement needs eight ranks"}
    end
  end

  defp row_squares([], acc), do: {:ok, Enum.reverse(acc) |> List.flatten()}

  defp row_squares([c | rest], acc) when c in ?1..?8,
    do: row_squares(rest, [List.duplicate(nil, c - ?0) | acc])

  defp row_squares([c | rest], acc) do
    case piece_from_char(c) do
      nil -> :error
      piece -> row_squares(rest, [[piece] | acc])
    end
  end

  defp piece_from_char(c) do
    white? = c in ?A..?Z
    lower = if white?, do: c + 32, else: c

    case Map.fetch(%{?p => :p, ?n => :n, ?b => :b, ?r => :r, ?q => :q, ?k => :k}, lower) do
      {:ok, kind} -> {if(white?, do: :w, else: :b), kind}
      :error -> nil
    end
  end

  defp turn("w"), do: {:ok, :w}
  defp turn("b"), do: {:ok, :b}
  defp turn(_other), do: {:error, "the FEN's side to move must be w or b"}

  defp castling("-"), do: {:ok, []}

  defp castling(text) do
    chars = String.graphemes(text)

    if chars != [] and Enum.all?(chars, &(&1 in ~w(K Q k q))) and chars == Enum.uniq(chars),
      do: {:ok, chars},
      else: {:error, "the FEN's castling field is malformed"}
  end

  defp ep_square("-"), do: {:ok, nil}

  defp ep_square(<<f, r>>) when f in ?a..?h and r in [?3, ?6], do: {:ok, index(f - ?a, ?8 - r)}
  defp ep_square(_other), do: {:error, "the FEN's en passant square is malformed"}

  defp counter(text, minimum) do
    case Integer.parse(text) do
      {n, ""} when n >= minimum and n < 10_000 -> {:ok, n}
      _bad -> {:error, "the FEN's move counters must be numbers"}
    end
  end

  defp sane(board) do
    squares = Tuple.to_list(board)
    kings = fn colour -> Enum.count(squares, &(&1 == {colour, :k})) end

    back_pawns =
      Enum.any?(0..7, fn f ->
        match?({_, :p}, elem(board, f)) or match?({_, :p}, elem(board, 56 + f))
      end)

    cond do
      kings.(:w) != 1 or kings.(:b) != 1 -> {:error, "each side needs exactly one king"}
      back_pawns -> {:error, "a pawn cannot stand on the first or last rank"}
      true -> :ok
    end
  end

  @doc "The FEN of a position."
  @spec to_fen(position()) :: String.t()
  def to_fen(pos) do
    placement =
      0..7
      |> Enum.map_join("/", fn row ->
        0..7
        |> Enum.map(&elem(pos.board, row * 8 + &1))
        |> Enum.chunk_by(&is_nil/1)
        |> Enum.map_join(fn
          [nil | _] = empties -> Integer.to_string(length(empties))
          pieces -> Enum.map_join(pieces, &char/1)
        end)
      end)

    castling =
      case Enum.filter(~w(K Q k q), &(&1 in pos.castling)) do
        [] -> "-"
        kept -> Enum.join(kept)
      end

    ep = if pos.ep, do: name(pos.ep), else: "-"

    "#{placement} #{pos.turn} #{castling} #{ep} #{pos.halfmove} #{pos.fullmove}"
  end

  defp char({colour, kind}) do
    letter = kind |> Atom.to_string()
    if colour == :w, do: String.upcase(letter), else: letter
  end

  # --- squares -----------------------------------------------------------------

  defp index(file, row), do: row * 8 + file
  defp file(i), do: rem(i, 8)
  defp row(i), do: div(i, 8)

  @doc "`\"e4\"` for square index 36."
  def name(i), do: <<?a + file(i), ?8 - row(i)>>

  defp square_index(<<f, r>>) when f in ?a..?h and r in ?1..?8, do: index(f - ?a, ?8 - r)

  defp inside?(file, row), do: file in 0..7 and row in 0..7

  # --- attacks -----------------------------------------------------------------

  @doc "Is `square` attacked by a piece of colour `by`?"
  def attacked?(board, square, by) do
    f = file(square)
    r = row(square)

    pawn_row = if by == :w, do: r + 1, else: r - 1

    pawn? =
      Enum.any?([f - 1, f + 1], fn pf ->
        inside?(pf, pawn_row) and elem(board, index(pf, pawn_row)) == {by, :p}
      end)

    pawn? or
      jumper?(board, f, r, @knight, {by, :n}) or
      jumper?(board, f, r, @king, {by, :k}) or
      slider?(board, f, r, @rook, [:r, :q], by) or
      slider?(board, f, r, @bishop, [:b, :q], by)
  end

  defp jumper?(board, f, r, offsets, piece),
    do:
      Enum.any?(offsets, fn {df, dr} ->
        inside?(f + df, r + dr) and elem(board, index(f + df, r + dr)) == piece
      end)

  defp slider?(board, f, r, directions, kinds, by) do
    Enum.any?(directions, fn {df, dr} -> ray_hits?(board, f + df, r + dr, df, dr, kinds, by) end)
  end

  defp ray_hits?(board, f, r, df, dr, kinds, by) do
    if inside?(f, r) do
      case elem(board, index(f, r)) do
        nil -> ray_hits?(board, f + df, r + dr, df, dr, kinds, by)
        {^by, kind} -> kind in kinds
        _other -> false
      end
    else
      false
    end
  end

  @doc "Is the side `colour` in check?"
  def in_check?(%{board: board}, colour) do
    king = Enum.find(0..63, &(elem(board, &1) == {colour, :k}))
    attacked?(board, king, opposite(colour))
  end

  defp opposite(:w), do: :b
  defp opposite(:b), do: :w

  # --- moves -------------------------------------------------------------------

  @doc "Every legal move of the side to move."
  @spec legal_moves(position()) :: [move()]
  def legal_moves(pos) do
    pos
    |> pseudo_legal()
    |> Enum.filter(fn move ->
      not in_check?(apply_move(pos, move), pos.turn)
    end)
  end

  defp pseudo_legal(pos) do
    for i <- 0..63,
        {colour, kind} <- [elem(pos.board, i)],
        colour == pos.turn,
        move <- piece_moves(pos, i, kind),
        do: move
  end

  defp piece_moves(pos, i, :n), do: steps(pos, i, :n, @knight)
  defp piece_moves(pos, i, :k), do: steps(pos, i, :k, @king) ++ castles(pos, i)
  defp piece_moves(pos, i, :r), do: slides(pos, i, :r, @rook)
  defp piece_moves(pos, i, :b), do: slides(pos, i, :b, @bishop)
  defp piece_moves(pos, i, :q), do: slides(pos, i, :q, @rook ++ @bishop)
  defp piece_moves(pos, i, :p), do: pawn_moves(pos, i)

  defp steps(pos, i, kind, offsets) do
    for {df, dr} <- offsets,
        f <- [file(i) + df],
        r <- [row(i) + dr],
        inside?(f, r),
        target <- [elem(pos.board, index(f, r))],
        is_nil(target) or elem(target, 0) != pos.turn,
        do: move(i, index(f, r), kind, target)
  end

  defp slides(pos, i, kind, directions) do
    Enum.flat_map(directions, fn {df, dr} ->
      ray(pos, i, kind, file(i) + df, row(i) + dr, df, dr, [])
    end)
  end

  defp ray(pos, from, kind, f, r, df, dr, acc) do
    if inside?(f, r) do
      to = index(f, r)

      case elem(pos.board, to) do
        nil ->
          ray(pos, from, kind, f + df, r + dr, df, dr, [move(from, to, kind, nil) | acc])

        {colour, _} = target when colour != pos.turn ->
          [move(from, to, kind, target) | acc]

        _own ->
          acc
      end
    else
      acc
    end
  end

  defp move(from, to, piece, target, extra \\ %{}) do
    Map.merge(
      %{
        from: from,
        to: to,
        piece: piece,
        capture: target && elem(target, 1),
        promo: nil,
        kind: :normal
      },
      extra
    )
  end

  defp pawn_moves(pos, i) do
    {dr, start_row, last_row} = if pos.turn == :w, do: {-1, 6, 0}, else: {1, 1, 7}
    f = file(i)
    r = row(i)
    ahead = r + dr

    pushes =
      if elem(pos.board, index(f, ahead)) == nil do
        single = move(i, index(f, ahead), :p, nil)

        double =
          if r == start_row and elem(pos.board, index(f, ahead + dr)) == nil,
            do: [move(i, index(f, ahead + dr), :p, nil, %{kind: :double})],
            else: []

        [single | double]
      else
        []
      end

    captures =
      for df <- [-1, 1],
          inside?(f + df, ahead),
          to <- [index(f + df, ahead)],
          target <- [elem(pos.board, to)],
          (target != nil and elem(target, 0) != pos.turn) or
            (target == nil and pos.ep == to),
          do:
            if(target == nil,
              do: %{move(i, to, :p, {opposite(pos.turn), :p}) | kind: :ep},
              else: move(i, to, :p, target)
            )

    Enum.flat_map(pushes ++ captures, fn m ->
      if row(m.to) == last_row,
        do: for(kind <- [:q, :r, :b, :n], do: %{m | promo: kind}),
        else: [m]
    end)
  end

  defp castles(pos, i) do
    {home, king_right, queen_right} = if pos.turn == :w, do: {60, "K", "Q"}, else: {4, "k", "q"}
    them = opposite(pos.turn)

    if i == home and not attacked?(pos.board, home, them) do
      [
        {king_right, :castle_k, [home + 1, home + 2], [home + 1, home + 2], home + 3},
        {queen_right, :castle_q, [home - 1, home - 2, home - 3], [home - 1, home - 2], home - 4}
      ]
      |> Enum.filter(fn {right, _kind, empty, safe, rook} ->
        right in pos.castling and elem(pos.board, rook) == {pos.turn, :r} and
          Enum.all?(empty, &(elem(pos.board, &1) == nil)) and
          not Enum.any?(safe, &attacked?(pos.board, &1, them))
      end)
      |> Enum.map(fn {_right, kind, _empty, _safe, _rook} ->
        move(home, if(kind == :castle_k, do: home + 2, else: home - 2), :k, nil, %{kind: kind})
      end)
    else
      []
    end
  end

  @doc "The position after `move`, which is assumed to be pseudo-legal."
  @spec apply_move(position(), move()) :: position()
  def apply_move(pos, m) do
    us = pos.turn
    placed = if m.promo, do: {us, m.promo}, else: {us, m.piece}

    board =
      pos.board
      |> put_elem(m.from, nil)
      |> put_elem(m.to, placed)
      |> then(fn board ->
        case m.kind do
          :ep -> put_elem(board, m.to + if(us == :w, do: 8, else: -8), nil)
          :castle_k -> board |> put_elem(m.to + 1, nil) |> put_elem(m.to - 1, {us, :r})
          :castle_q -> board |> put_elem(m.to - 2, nil) |> put_elem(m.to + 1, {us, :r})
          _plain -> board
        end
      end)

    castling =
      Enum.reject(pos.castling, fn right ->
        right in lost_rights(m.from) or right in lost_rights(m.to)
      end)

    %{
      pos
      | board: board,
        turn: opposite(us),
        castling: castling,
        ep: if(m.kind == :double, do: div(m.from + m.to, 2), else: nil),
        halfmove: if(m.piece == :p or m.capture, do: 0, else: pos.halfmove + 1),
        fullmove: if(us == :b, do: pos.fullmove + 1, else: pos.fullmove)
    }
  end

  defp lost_rights(60), do: ["K", "Q"]
  defp lost_rights(4), do: ["k", "q"]
  defp lost_rights(63), do: ["K"]
  defp lost_rights(56), do: ["Q"]
  defp lost_rights(7), do: ["k"]
  defp lost_rights(0), do: ["q"]
  defp lost_rights(_other), do: []

  @doc "Counts the leaf positions `depth` plies down - the standard way to prove a move generator."
  @spec perft(position(), non_neg_integer()) :: non_neg_integer()
  def perft(_pos, 0), do: 1

  def perft(pos, 1), do: length(legal_moves(pos))

  def perft(pos, depth),
    do: pos |> legal_moves() |> Enum.reduce(0, &(perft(apply_move(pos, &1), depth - 1) + &2))

  # --- what a position is ------------------------------------------------------

  @doc """
  `:checkmate`, `:stalemate`, `:insufficient_material` or `:playing`. The
  draws that need a history (repetition) or a claim (fifty moves) are not
  decided here: a relay reports those as a result.
  """
  @spec state(position()) :: :checkmate | :stalemate | :insufficient_material | :playing
  def state(pos) do
    cond do
      legal_moves(pos) == [] -> if in_check?(pos, pos.turn), do: :checkmate, else: :stalemate
      insufficient?(pos) -> :insufficient_material
      true -> :playing
    end
  end

  defp insufficient?(%{board: board}) do
    pieces = board |> Tuple.to_list() |> Enum.reject(&(is_nil(&1) or elem(&1, 1) == :k))

    case pieces do
      [] -> true
      [{_, kind}] -> kind in [:n, :b]
      _more -> false
    end
  end

  # --- SAN ---------------------------------------------------------------------

  @doc "The SAN of a legal `move`, check and mate marks included."
  @spec san(position(), move()) :: String.t()
  def san(pos, move) do
    base = base_san(pos, move, legal_moves(pos))
    after_move = apply_move(pos, move)

    suffix =
      cond do
        not in_check?(after_move, after_move.turn) -> ""
        legal_moves(after_move) == [] -> "#"
        true -> "+"
      end

    base <> suffix
  end

  defp base_san(_pos, %{kind: :castle_k}, _legal), do: "O-O"
  defp base_san(_pos, %{kind: :castle_q}, _legal), do: "O-O-O"

  defp base_san(_pos, %{piece: :p} = m, _legal) do
    from_file = <<?a + file(m.from)>>
    target = name(m.to)

    lead = if m.capture, do: from_file <> "x" <> target, else: target
    if m.promo, do: lead <> "=" <> String.upcase(Atom.to_string(m.promo)), else: lead
  end

  defp base_san(_pos, m, legal) do
    rivals =
      Enum.filter(legal, &(&1.piece == m.piece and &1.to == m.to and &1.from != m.from))

    disambiguation =
      cond do
        rivals == [] -> ""
        Enum.all?(rivals, &(file(&1.from) != file(m.from))) -> <<?a + file(m.from)>>
        Enum.all?(rivals, &(row(&1.from) != row(m.from))) -> <<?8 - row(m.from)>>
        true -> name(m.from)
      end

    String.upcase(Atom.to_string(m.piece)) <>
      disambiguation <> if(m.capture, do: "x", else: "") <> name(m.to)
  end

  @san ~r/^([NBRQK])?([a-h])?([1-8])?[x:-]?([a-h][1-8])(?:=?([NBRQnbrq]))?$/

  @doc """
  Reads `text` as a move of `pos`. Lenient about what relays get wrong - a
  missing `x`, a missing or surplus check mark, `0-0`, `e8Q`, an unneeded
  disambiguation - and strict about what matters: it names exactly one legal
  move or it is an error.
  """
  @spec parse_san(position(), term()) :: {:ok, move()} | {:error, String.t()}
  def parse_san(pos, text) when is_binary(text) do
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/[+#!?]+$/, "")
      |> String.replace(~r/\s*e\.p\.$/, "")

    legal = legal_moves(pos)

    cond do
      cleaned in ["O-O", "0-0", "o-o"] -> pick(legal, &(&1.kind == :castle_k), text)
      cleaned in ["O-O-O", "0-0-0", "o-o-o"] -> pick(legal, &(&1.kind == :castle_q), text)
      true -> parse_regular(legal, cleaned, text)
    end
  end

  def parse_san(_pos, other), do: {:error, "a move must be a string, got #{inspect(other)}"}

  defp parse_regular(legal, cleaned, original) do
    case Regex.run(@san, cleaned) do
      nil ->
        {:error, "#{inspect(original)} is not a move in algebraic notation"}

      [_ | groups] ->
        [piece, from_file, from_rank, to, promo] =
          groups ++ List.duplicate("", 5 - length(groups))

        kind = if piece == "", do: :p, else: piece |> String.downcase() |> String.to_atom()
        promo_kind = if promo == "", do: nil, else: promo |> String.downcase() |> String.to_atom()
        to = square_index(to)

        pick(
          legal,
          fn m ->
            m.piece == kind and m.to == to and m.promo == promo_kind and
              (kind != :p or from_file != "" or m.capture == nil) and
              (from_file == "" or file(m.from) == hd(String.to_charlist(from_file)) - ?a) and
              (from_rank == "" or row(m.from) == ?8 - hd(String.to_charlist(from_rank)))
          end,
          original
        )
    end
  end

  defp pick(legal, fun, original) do
    case Enum.filter(legal, fun) do
      [move] -> {:ok, move}
      [] -> {:error, "#{inspect(original)} is not a legal move here"}
      _several -> {:error, "#{inspect(original)} is ambiguous here"}
    end
  end

  @doc """
  Plays `sans` from `fen`, returning the position after each move.

  `{:ok, plies}` where each ply is `%{san: canonical_san, fen: fen_after}`,
  or `{:error, {ply, message}}` naming the first move (1-based) that is not
  legal.
  """
  @spec replay(String.t(), [String.t()]) ::
          {:ok, [%{san: String.t(), fen: String.t()}]}
          | {:error, {pos_integer(), String.t()}}
          | {:error, String.t()}
  def replay(fen, sans) when is_list(sans) do
    with {:ok, pos} <- parse_fen(fen) do
      sans
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, pos, []}, fn {text, ply}, {:ok, pos, acc} ->
        case parse_san(pos, text) do
          {:ok, move} ->
            canonical = san(pos, move)
            next = apply_move(pos, move)
            {:cont, {:ok, next, [%{san: canonical, fen: to_fen(next)} | acc]}}

          {:error, message} ->
            {:halt, {:error, {ply, message}}}
        end
      end)
      |> case do
        {:ok, _pos, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  @doc """
  The piece on each square as `[{square_name, {colour, kind}}]`, for drawing.
  """
  def pieces(%{board: board}) do
    for i <- 0..63, piece = elem(board, i), do: {i, piece}
  end

  @doc "The squares a move starts and ends on, from a SAN played in `fen`."
  def last_squares(fen_before, san) do
    with {:ok, pos} <- parse_fen(fen_before),
         {:ok, move} <- parse_san(pos, san) do
      {move.from, move.to}
    else
      _error -> nil
    end
  end
end
