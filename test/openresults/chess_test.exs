defmodule OpenResults.ChessTest do
  @moduledoc """
  The move checker behind the live-board ingest, proved the way move
  generators are: by counting positions (perft) against the published
  numbers for the standard test positions - which between them exercise
  castling in every shape, en passant (including the discovered-check
  case), promotion to every piece, pins, and check evasions - and then SAN,
  FEN and the game states on top.
  """

  use ExUnit.Case, async: true

  alias OpenResults.Chess

  defp position!(fen) do
    {:ok, position} = Chess.parse_fen(fen)
    position
  end

  # The numbers are from the Chess Programming Wiki's perft results.
  @perft [
    {"the starting position", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
     [20, 400, 8902]},
    {"Kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
     [48, 2039]},
    {"position 3 (en passant, pins, a rook ending)", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
     [14, 191, 2812]},
    {"position 4 (promotions and castling through check)",
     "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", [6, 264, 9467]},
    {"position 4, mirrored", "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
     [6, 264, 9467]},
    {"position 5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", [44, 1486]},
    {"position 6", "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
     [46, 2079]}
  ]

  describe "perft" do
    for {name, fen, counts} <- @perft do
      test "counts #{name} correctly" do
        position = position!(unquote(fen))

        for {expected, depth} <- Enum.with_index(unquote(counts), 1) do
          assert Chess.perft(position, depth) == expected, "depth #{depth}"
        end
      end
    end
  end

  describe "FEN" do
    test "round-trips the positions above" do
      for {_name, fen, _counts} <- @perft do
        assert fen |> position!() |> Chess.to_fen() == fen
      end
    end

    test "the two move counters may be left off" do
      assert {:ok, position} = Chess.parse_fen("8/8/8/4k3/8/8/4K3/8 w - -")
      assert {position.halfmove, position.fullmove} == {0, 1}
    end

    test "refuses what is not a position" do
      for bad <- [
            "",
            "nonsense",
            "8/8/8/8/8/8/8 w - - 0 1",
            "8/8/8/8/8/8/8/8 w - - 0 1",
            "k7/8/8/8/8/8/8/KK6 w - - 0 1",
            "P3k3/8/8/8/8/8/8/4K3 w - - 0 1",
            "4k3/8/8/8/8/8/8/4K3 x - - 0 1",
            "4k3/8/8/8/8/8/8/4K3 w KK - 0 1",
            "4k3/8/8/8/8/8/8/4K3 w - e4 0 1",
            "4k3/8/8/8/8/8/8/4K3 w - - x 1",
            "9/8/8/8/8/8/8/8 w - - 0 1",
            "4k3/8/8/8/8/8/8/4Z3 w - - 0 1"
          ] do
        assert {:error, message} = Chess.parse_fen(bad), "accepted #{inspect(bad)}"
        assert is_binary(message)
      end

      assert {:error, _} = Chess.parse_fen(nil)
    end
  end

  describe "replaying a game" do
    test "the Opera Game ends in checkmate, and every move is written canonically" do
      moves =
        ~w(e4 e5 Nf3 d6 d4 Bg4 dxe5 Bxf3 Qxf3 dxe5 Bc4 Nf6 Qb3 Qe7 Nc3 c6 Bg5 b5 Nxb5 cxb5
           Bxb5+ Nbd7 O-O-O Rd8 Rxd7 Rxd7 Rd1 Qe6 Bxd7+ Nxd7 Qb8+ Nxb8 Rd8#)

      assert {:ok, plies} = Chess.replay(Chess.start_fen(), moves)
      assert Enum.map(plies, & &1.san) == moves

      assert plies |> List.last() |> Map.fetch!(:fen) |> position!() |> Chess.state() ==
               :checkmate
    end

    test "reads the loose spellings relays produce, and writes them canonically" do
      # A check mark that is not a check is dropped, not an error.
      assert {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Nf3+ Nc6 Bb5 a6 0-0))
      assert Enum.map(plies, & &1.san) == ~w(e4 e5 Nf3 Nc6 Bb5 a6 O-O)
    end

    test "castling that is not possible is an error naming the ply" do
      assert {:error, {3, _}} = Chess.replay(Chess.start_fen(), ~w(e4 e5 0-0))
    end

    test "castles both ways, from the loose spellings too" do
      assert {:ok, plies} =
               Chess.replay(
                 "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
                 ~w(0-0 o-o-o)
               )

      assert Enum.map(plies, & &1.san) == ["O-O", "O-O-O"]
      assert List.last(plies).fen == "2kr3r/8/8/8/8/8/8/R4RK1 w - - 2 2"
    end

    test "en passant, captured and written" do
      assert {:ok, plies} = Chess.replay(Chess.start_fen(), ~w(e4 a6 e5 d5 exd6))
      assert List.last(plies).fen == "rnbqkbnr/1pp1pppp/p2P4/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 3"
    end

    test "promotion needs its piece, and writes it with =" do
      fen = "7k/P7/8/8/8/8/8/K7 w - - 0 1"
      assert {:ok, [%{san: "a8=Q+"}]} = Chess.replay(fen, ["a8Q"])
      assert {:ok, [%{san: "a8=N"}]} = Chess.replay(fen, ["a8=N"])
      assert {:error, {1, message}} = Chess.replay(fen, ["a8"])
      assert message =~ "not a legal move"
    end

    test "disambiguates when two pieces can go, and refuses an ambiguous move" do
      fen = "4k3/8/8/8/8/8/8/N1N1K3 w - - 0 1"
      assert {:ok, [%{san: "Nab3"}]} = Chess.replay(fen, ["Nab3"])
      assert {:error, {1, message}} = Chess.replay(fen, ["Nb3"])
      assert message =~ "ambiguous"
      # Over-disambiguating is harmless.
      assert {:ok, [%{san: "Nab3"}]} = Chess.replay(fen, ["Na1b3"])

      # Three queens that can reach c3: neither the file nor the rank alone
      # tells the one on a1 from the other two.
      three = "7k/8/8/8/8/Q7/8/Q1Q1K3 w - - 0 1"
      assert {:ok, [%{san: "Qa1c3+"}]} = Chess.replay(three, ["Qa1c3"])
      assert {:ok, [%{san: "Q3c3+"}]} = Chess.replay(three, ["Q3c3"])
    end

    test "a pinned piece cannot move, and a move into check is refused" do
      pinned = "4k3/4r3/8/8/8/8/4N3/4K3 w - - 0 1"
      assert {:error, {1, _}} = Chess.replay(pinned, ["Nc3"])
      assert {:error, {1, _}} = Chess.replay("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1", ["Kd2"])
    end

    test "names the first illegal ply" do
      assert {:error, {3, message}} = Chess.replay(Chess.start_fen(), ~w(e4 e5 Ke3))
      assert message =~ "Ke3"
    end

    test "an unreadable move is an error, not a crash" do
      for junk <- ["", "xx", "Z9", "e4e5", "O-O-O-O", "N", "  "] do
        assert {:error, {1, _}} = Chess.replay(Chess.start_fen(), [junk])
      end
    end
  end

  describe "what a position is" do
    test "checkmate, stalemate, bare kings and a game in progress" do
      assert "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1" |> position!() |> Chess.state() == :stalemate
      assert "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1" |> position!() |> Chess.state() == :checkmate

      assert "8/8/8/4k3/8/8/4K3/8 w - - 0 1" |> position!() |> Chess.state() ==
               :insufficient_material

      assert "8/8/8/4k3/8/8/4KN2/8 w - - 0 1" |> position!() |> Chess.state() ==
               :insufficient_material

      assert "8/8/8/4k3/8/8/4KP2/8 w - - 0 1" |> position!() |> Chess.state() == :playing
      assert Chess.start() |> Chess.state() == :playing
    end

    test "attacked?/3 and in_check?/2 agree on a check" do
      position = position!("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1")
      assert Chess.in_check?(position, :w)
      refute Chess.in_check?(position, :b)
    end

    test "last_squares/2 finds where a move went, for highlighting" do
      assert Chess.last_squares(Chess.start_fen(), "e4") == {52, 36}
      assert Chess.last_squares(Chess.start_fen(), "Ke2") == nil
    end

    test "name/1 writes square names" do
      assert Chess.name(0) == "a8"
      assert Chess.name(63) == "h1"
      assert Chess.name(36) == "e4"
    end
  end
end
