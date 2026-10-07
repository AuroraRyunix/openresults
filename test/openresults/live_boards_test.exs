defmodule OpenResults.LiveBoardsTest do
  @moduledoc """
  The live-board store: what an update must look like, what it does to a
  game already held (idempotent, order-tolerant, never going backwards), the
  broadcast delay applied on reading, the PGN, the simulator's plan, and the
  takedown.
  """

  use OpenResults.DataCase, async: false

  alias OpenResults.Chess
  alias OpenResults.LiveBoards
  alias OpenResults.LiveBoards.Pgn
  alias OpenResults.LiveBoards.PgnReader
  alias OpenResults.LiveBoards.Simulator
  alias OpenResults.Moderation
  alias OpenResults.PublicPublishingFixtures
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.Takedown

  @t0 1_800_000_000_000

  setup do
    {:ok, slug: PublicPublishingFixtures.unique_slug("live")}
  end

  defp upd(round \\ 1, board \\ 1, extra) do
    Map.merge(
      %{"round" => round, "board" => board},
      Map.new(extra, fn {k, v} -> {to_string(k), v} end)
    )
  end

  defp ingest!(slug, params, now_ms \\ @t0) do
    assert {:ok, outcome} = LiveBoards.ingest(slug, params, now_ms: now_ms)
    outcome
  end

  defp game(slug, round \\ 1, board \\ 1), do: LiveBoards.get_game(slug, round, board)

  describe "what an update must look like" do
    test "needs a round and a board, and either moves or a position", %{slug: slug} do
      assert {:error, :invalid_request, detail} =
               LiveBoards.ingest(slug, %{"board" => 1, "moves" => []})

      assert detail =~ "round"

      assert {:error, :invalid_request, _} =
               LiveBoards.ingest(slug, %{"round" => 1, "moves" => []})

      assert {:error, :invalid_request, _} = LiveBoards.ingest(slug, upd(white_ms: 1000))

      assert {:error, :invalid_request, _} =
               LiveBoards.ingest(slug, upd(fen: Chess.start_fen()))

      assert {:error, :invalid_request, _} = LiveBoards.ingest(slug, upd(ply: 3))
      assert {:error, :invalid_request, _} = LiveBoards.ingest(slug, "not an object")
      assert game(slug) == nil
    end

    test "refuses values out of range or of the wrong type", %{slug: slug} do
      for bad <- [
            upd(round: 0, moves: []),
            upd(board: 10_000, moves: []),
            upd(round: "1", moves: []),
            upd(moves: [], white_ms: -1),
            upd(moves: [], white_ms: "slow"),
            upd(moves: [], running: "both"),
            upd(moves: [], status: "paused"),
            upd(moves: [], result: "2-0"),
            upd(moves: [], replace: "yes")
          ] do
        assert {:error, :invalid_request, _} = LiveBoards.ingest(slug, bad), inspect(bad)
      end
    end

    test "refuses moves that are not a list of strings, or too many", %{slug: slug} do
      assert {:error, :invalid_moves, _} = LiveBoards.ingest(slug, upd(moves: "e4"))
      assert {:error, :invalid_moves, _} = LiveBoards.ingest(slug, upd(moves: [1, 2]))

      assert {:error, :invalid_moves, _} =
               LiveBoards.ingest(slug, upd(moves: List.duplicate("Nf3", 701)))
    end

    test "refuses a FEN that is not a position, and a ply that disagrees with the moves", %{
      slug: slug
    } do
      assert {:error, :invalid_fen, _} = LiveBoards.ingest(slug, upd(moves: [], fen: "junk"))
      assert {:error, :invalid_fen, _} = LiveBoards.ingest(slug, upd(moves: [], start_fen: 7))
      assert {:error, :ply_mismatch, _} = LiveBoards.ingest(slug, upd(moves: ["e4"], ply: 2))
    end

    test "names the first illegal ply and stores nothing", %{slug: slug} do
      assert {:error, :invalid_moves, detail, %{ply: 3}} =
               LiveBoards.ingest(slug, upd(moves: ~w(e4 e5 Ke3)))

      assert detail =~ "ply 3"
      assert game(slug) == nil
    end

    test "a FEN beside the moves has to be where they lead", %{slug: slug} do
      {:ok, [%{fen: after_e4}]} = Chess.replay(Chess.start_fen(), ["e4"])
      assert %{applied?: true} = ingest!(slug, upd(moves: ["e4"], fen: after_e4))

      assert {:error, :fen_mismatch, _} =
               LiveBoards.ingest(slug, upd(2, moves: ["e4"], fen: Chess.start_fen()))

      # Move counters are the relay's own business.
      assert {:ok, _} =
               LiveBoards.ingest(
                 slug,
                 upd(3,
                   moves: ["e4"],
                   fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 5 9"
                 )
               )
    end
  end

  describe "ingest: idempotent, tolerant of order, never going backwards" do
    test "stores a game and canonicalises its moves", %{slug: slug} do
      assert %{applied?: true, ply: 3} =
               ingest!(
                 slug,
                 upd(
                   moves: ["e4", "e5", "Nf3+"],
                   white_ms: 60_000,
                   black_ms: 59_000,
                   running: "black"
                 )
               )

      game = game(slug)
      assert Enum.map(game.plies, & &1["san"]) == ["e4", "e5", "Nf3"]
      assert game.ply_count == 3
      assert game.fen == "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"
      assert {game.white_ms, game.black_ms, game.running} == {60_000, 59_000, "black"}
      assert game.status == "live"
    end

    test "the same update twice is the same game", %{slug: slug} do
      params = upd(moves: ~w(e4 e5), white_ms: 1000)
      ingest!(slug, params)
      first = game(slug)
      assert %{applied?: true, ply: 2} = ingest!(slug, params, @t0 + 5000)
      again = game(slug)

      assert again.plies == first.plies
      assert again.moved_at_ms == first.moved_at_ms
    end

    test "an older update never overwrites a newer one", %{slug: slug} do
      ingest!(slug, upd(moves: ~w(e4 e5 Nf3)))
      assert %{applied?: false, ply: 3} = ingest!(slug, upd(moves: ~w(e4 e5)))
      assert %{applied?: false} = ingest!(slug, upd(moves: [], white_ms: 5))
      assert game(slug).ply_count == 3
      assert game(slug).white_ms == nil
    end

    test "a longer update extends, and the old plies keep the time they were heard", %{slug: slug} do
      ingest!(slug, upd(moves: ~w(e4 e5)), @t0)
      ingest!(slug, upd(moves: ~w(e4 e5 Nf3 Nc6)), @t0 + 10_000)

      assert game(slug).plies |> Enum.map(& &1["at"]) == [@t0, @t0, @t0 + 10_000, @t0 + 10_000]
    end

    test "an update at the same ply refreshes clocks and status", %{slug: slug} do
      ingest!(slug, upd(moves: ~w(e4), white_ms: 100_000, black_ms: 100_000, running: "black"))
      ingest!(slug, upd(moves: ~w(e4), black_ms: 90_000), @t0 + 10_000)

      game = game(slug)
      assert {game.white_ms, game.black_ms, game.running} == {100_000, 90_000, "black"}
      assert game.clock_at_ms == @t0 + 10_000
    end

    test "moves that disagree with the held game are a conflict, unless replacing", %{slug: slug} do
      ingest!(slug, upd(moves: ~w(e4 e5 Nf3)))

      assert {:error, :moves_conflict, detail} =
               LiveBoards.ingest(slug, upd(moves: ~w(e4 c5 Nf3 d6)))

      assert detail =~ "move 2"
      assert game(slug).ply_count == 3

      assert %{applied?: true, ply: 2} =
               ingest!(slug, upd(moves: ~w(e4 c5), replace: true), @t0 + 1)

      assert game(slug).plies |> Enum.map(& &1["san"]) == ~w(e4 c5)
    end

    test "a replacement keeps the time of the plies that did not change", %{slug: slug} do
      ingest!(slug, upd(moves: ~w(e4 e5 Nf3)), @t0)
      ingest!(slug, upd(moves: ~w(e4 e5 Bc4 Nc6), replace: true), @t0 + 30_000)

      assert game(slug).plies |> Enum.map(&{&1["san"], &1["at"]}) ==
               [{"e4", @t0}, {"e5", @t0}, {"Bc4", @t0 + 30_000}, {"Nc6", @t0 + 30_000}]
    end

    test "a position alone is shown without a move list, and moves can follow it", %{slug: slug} do
      {:ok, [%{fen: fen}]} = Chess.replay(Chess.start_fen(), ["e4"])
      assert %{applied?: true, ply: 1} = ingest!(slug, upd(fen: fen, ply: 1))
      assert %{plies: [], fen: ^fen, ply_count: 1} = game(slug)

      assert %{applied?: true, ply: 2} = ingest!(slug, upd(moves: ~w(e4 e5)), @t0 + 1)
      assert game(slug).plies |> length() == 2
    end

    test "a round can be read without its move lists, and a tile still has its last move",
         %{slug: slug} do
      ingest!(slug, upd(moves: ~w(e4 e5 Nf3), white_ms: 1000))
      {:ok, [%{fen: fen}]} = Chess.replay(Chess.start_fen(), ["e4"])
      ingest!(slug, upd(1, 2, fen: fen, ply: 1))

      assert [light, bare] = LiveBoards.games_for_round(slug, 1, plies: false)
      assert light.plies == []
      view = LiveBoards.view(light, 0, @t0)
      assert {view.ply, view.last, view.last_san} == {3, {62, 45}, "Nf3"}
      assert view.clocks.white == 1000

      # A game known by position alone has no last move to show.
      assert {bare.last_from, bare.last_san} == {nil, nil}
      assert LiveBoards.view(bare, 0, @t0).last == nil
    end

    test "a game from another start position", %{slug: slug} do
      start = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
      assert %{applied?: true} = ingest!(slug, upd(moves: ~w(e4 Kd7), start_fen: start))
      assert game(slug).start_fen == start
      assert game(slug).fen == "8/3k4/8/8/4P3/8/8/4K3 w - - 1 2"
    end

    test "finishing: the result is kept, and a later live update does not reopen it", %{
      slug: slug
    } do
      ingest!(slug, upd(moves: ~w(f3 e5 g4 Qh4#)))

      ingest!(
        slug,
        upd(moves: ~w(f3 e5 g4 Qh4#), status: "finished", result: "0-1", running: "none"),
        @t0 + 100
      )

      game = game(slug)

      assert {game.status, game.result, game.running, game.finished_at_ms} ==
               {"finished", "0-1", nil, @t0 + 100}

      assert %{applied?: false} =
               ingest!(slug, upd(moves: ~w(f3 e5 g4 Qh4#), status: "live"), @t0 + 200)

      assert game(slug).status == "finished"

      # The same finish again keeps its first time.
      ingest!(slug, upd(moves: ~w(f3 e5 g4 Qh4#), status: "finished"), @t0 + 300)
      assert game(slug).finished_at_ms == @t0 + 100
      assert game(slug).result == "0-1"
    end

    test "a higher ply reopens a finished game, and replace does too", %{slug: slug} do
      ingest!(slug, upd(moves: ~w(e4 e5), status: "finished", result: "1/2-1/2"))
      assert %{applied?: true} = ingest!(slug, upd(moves: ~w(e4 e5 Nf3)), @t0 + 1)
      assert %{status: "live", result: nil} = game(slug)
    end

    test "boards and rounds are separate games", %{slug: slug} do
      ingest!(slug, upd(1, 1, moves: ~w(e4)))
      ingest!(slug, upd(1, 2, moves: ~w(d4)))
      ingest!(slug, upd(2, 1, moves: ~w(c4)))

      assert LiveBoards.games(slug) |> Enum.map(&{&1.round, &1.board, hd(&1.plies)["san"]}) ==
               [{1, 1, "e4"}, {1, 2, "d4"}, {2, 1, "c4"}]

      assert LiveBoards.rounds_with_games(slug) == [1, 2]
      assert LiveBoards.games_for_round(slug, 1) |> length() == 2
    end

    test "broadcasts a change, and says nothing for an update it ignored", %{slug: slug} do
      LiveBoards.subscribe(slug)
      ingest!(slug, upd(3, 7, moves: ~w(e4 e5)))
      assert_receive {:live_board, ^slug, 3, 7}

      ingest!(slug, upd(3, 7, moves: ~w(e4)))
      refute_receive {:live_board, _, _, _}, 50
    end
  end

  describe "the broadcast delay, applied on reading" do
    setup %{slug: slug} do
      ingest!(
        slug,
        upd(moves: ~w(e4), white_ms: 100_000, black_ms: 100_000, running: "black"),
        @t0
      )

      ingest!(
        slug,
        upd(moves: ~w(e4 e5), white_ms: 100_000, black_ms: 95_000, running: "white"),
        @t0 + 60_000
      )

      ingest!(
        slug,
        upd(moves: ~w(e4 e5 Nf3), white_ms: 90_000, black_ms: 95_000, running: "black"),
        @t0 + 120_000
      )

      {:ok, game: game(slug)}
    end

    test "without a delay it is the game as it stands, clocks counted down", %{game: game} do
      view = LiveBoards.view(game, 0, @t0 + 125_000)

      assert {view.ply, view.status} == {3, "live"}
      assert view.clocks == %{white: 90_000, black: 90_000, running: "black"}
    end

    test "with one, it is the game as it stood then", %{game: game} do
      view = LiveBoards.view(game, :timer.minutes(1), @t0 + 130_000)
      # The cutoff is @t0 + 70_000: two plies had been heard.
      assert {view.ply, Enum.map(view.plies, & &1["san"])} == {2, ["e4", "e5"]}
      assert view.fen == "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"
      assert view.last == {12, 28}
      # Black's clock was 95_000 and White's was running from @t0 + 60_000.
      assert view.clocks == %{white: 90_000, black: 95_000, running: "white"}
    end

    test "before the first move is old enough there is no game to show", %{game: game} do
      assert LiveBoards.view(game, :timer.minutes(10), @t0 + 120_000) == nil
    end

    test "a ply appears on the second the delay has passed", %{game: game} do
      delay = :timer.minutes(2)
      assert LiveBoards.view(game, delay, @t0 + 120_000 + delay - 1).ply == 2
      assert LiveBoards.view(game, delay, @t0 + 120_000 + delay).ply == 3
    end

    test "a result is hidden until its time", %{slug: slug} do
      ingest!(
        slug,
        upd(moves: ~w(e4 e5 Nf3), status: "finished", result: "1/2-1/2"),
        @t0 + 300_000
      )

      game = game(slug)

      assert %{status: "finished", result: "1/2-1/2"} = LiveBoards.view(game, 0, @t0 + 300_000)

      delayed = LiveBoards.view(game, :timer.minutes(2), @t0 + 400_000)
      assert delayed.status == "live"
      assert delayed.result == nil

      assert %{status: "finished", result: "1/2-1/2"} =
               LiveBoards.view(game, :timer.minutes(2), @t0 + 300_000 + :timer.minutes(2))
    end

    test "the setting is stored, validated and read back", %{slug: slug} do
      assert LiveBoards.delay_minutes(slug) == 0
      assert {:ok, 15} = LiveBoards.put_delay(slug, 15, "moderator@example.invalid")
      assert LiveBoards.delay_minutes(slug) == 15
      assert {:ok, 0} = LiveBoards.put_delay(slug, 0, "moderator@example.invalid")
      assert LiveBoards.delay_minutes(slug) == 0

      for bad <- [-1, 1441, 1.5, "10", nil] do
        assert {:error, :invalid} = LiveBoards.put_delay(slug, bad, "moderator@example.invalid")
      end
    end
  end

  describe "PGN" do
    test "writes the tags, the moves and the result", %{slug: slug} do
      ingest!(slug, upd(moves: ~w(f3 e5 g4 Qh4#), status: "finished", result: "0-1"))
      view = LiveBoards.view(game(slug), 0, @t0)

      pgn =
        Pgn.build(view, [
          {"Event", "A \"Quoted\" Open"},
          {"Site", nil},
          {"Date", "2026.03.05"},
          {"Round", "1.1"},
          {"White", "Ng, Ada"},
          {"Black", "Sol, Bo"},
          {"WhiteElo", 2100},
          {"BlackElo", nil}
        ])

      assert pgn =~ ~s([Event "A \\"Quoted\\" Open"])
      assert pgn =~ ~s([Site "?"])
      assert pgn =~ ~s([White "Ng, Ada"])
      assert pgn =~ ~s([WhiteElo "2100"])
      refute pgn =~ "BlackElo"
      assert pgn =~ ~s([Result "0-1"])
      assert pgn =~ "\n\n1. f3 e5 2. g4 Qh4# 0-1\n"
      refute pgn =~ "SetUp"
    end

    test "a tag value is one line, whatever the name holds", %{slug: slug} do
      ingest!(slug, upd(moves: ~w(e4)))
      view = LiveBoards.view(game(slug), 0, @t0)
      pgn = Pgn.build(view, [{"White", "Eve\n[Result \"1-0\"]"}, {"Black", "B"}])

      assert pgn =~ ~s([White "Eve [Result \\"1-0\\"]"])
      assert pgn |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "[Result")) == 1
    end

    test "a game in progress ends in *, and a custom start carries its FEN", %{slug: slug} do
      start = "4k3/8/8/8/8/8/4P3/4K3 b - - 0 7"
      ingest!(slug, upd(moves: ~w(Kd7 e4), start_fen: start))
      view = LiveBoards.view(game(slug), 0, @t0)
      pgn = Pgn.build(view, [{"White", "A"}, {"Black", "B"}])

      assert pgn =~ ~s([SetUp "1"])
      assert pgn =~ ~s([FEN "#{start}"])
      assert pgn =~ "7... Kd7 8. e4 *\n"
      assert pgn =~ ~s([Result "*"])
    end

    test "long games wrap at 80 columns", %{slug: slug} do
      moves = List.flatten(List.duplicate(~w(Nf3 Nf6 Ng1 Ng8), 12))
      ingest!(slug, upd(moves: moves))
      pgn = Pgn.build(LiveBoards.view(game(slug), 0, @t0), [])

      lines = pgn |> String.split("\n\n") |> List.last() |> String.split("\n", trim: true)
      assert length(lines) > 1
      assert Enum.all?(lines, &(String.length(&1) <= 80))
    end
  end

  describe "the PGN reader and the simulator's plan" do
    @pgn """
    [Event "Test"]
    [White "Ada"]
    [Black "Bo"]
    [Result "1-0"]

    1. e4 {[%clk 0:05:00]} e5 {[%clk 0:04:58]} 2. Nf3 $1 (2. f4 exf4) 2... Nc6 ; a comment
    3. Bb5! a6 1-0

    [Event "Second"]
    [White "Cy"]
    [Black "Di"]

    1. d4 d5 *
    """

    test "reads games, skipping comments, variations and glyphs" do
      assert [first, second] = PgnReader.parse(@pgn)
      assert first.moves == ~w(e4 e5 Nf3 Nc6 Bb5 a6)
      assert first.clocks == [300_000, 298_000, nil, nil, nil, nil]
      assert first.result == "1-0"
      assert first.headers["White"] == "Ada"
      assert second.moves == ~w(d4 d5)
      assert second.result == "*"
    end

    test "the shipped fixtures are legal games and end as their result says" do
      games = Simulator.load(Path.wildcard("priv/live_sim/*.pgn"))
      assert length(games) == 3

      for game <- games do
        assert {:ok, plies} = Chess.replay(Chess.start_fen(), game.moves), game.headers["White"]
        assert game.result == "1-0"

        assert plies
               |> List.last()
               |> Map.fetch!(:fen)
               |> then(&Chess.parse_fen/1)
               |> elem(1)
               |> Chess.state() ==
                 :checkmate
      end
    end

    test "a plan, sent in order, reproduces the game through the ingest", %{slug: slug} do
      [game | _] = Simulator.load(["priv/live_sim/opera-game-1858.pgn"])
      plan = Simulator.plan(game, board: 4, round: 2, speed: 60.0)

      assert length(plan) == length(game.moves) + 2
      assert {0, %{"moves" => [], "running" => "white"}} = hd(plan)

      for {{_wait, body}, i} <- Enum.with_index(plan) do
        assert %{applied?: true} = ingest!(slug, body, @t0 + i * 1000)
      end

      stored = game(slug, 2, 4)
      assert Enum.map(stored.plies, & &1["san"]) == game.moves
      assert stored.status == "finished"
      assert stored.result == "1-0"
      assert stored.running == nil
    end

    test "a plan is the same twice, and different by seed" do
      [game | _] = Simulator.load(["priv/live_sim/opera-game-1858.pgn"])
      assert Simulator.plan(game, board: 1) == Simulator.plan(game, board: 1)
      refute Simulator.plan(game, board: 1) == Simulator.plan(game, board: 1, seed: 2)
    end
  end

  describe "taking a tournament down" do
    test "removes its live games and its delay", %{slug: slug} do
      {:ok, _} = Snapshots.ingest(put_in(SnapshotPayloads.swiss(), ["tournament", "slug"], slug))
      ingest!(slug, upd(moves: ~w(e4)))
      {:ok, _} = LiveBoards.put_delay(slug, 10, "moderator@example.invalid")

      Takedown.purge(slug)

      assert LiveBoards.games(slug) == []
      assert LiveBoards.delay_minutes(slug) == 0
    end

    test "another tournament's games are left alone", %{slug: slug} do
      other = PublicPublishingFixtures.unique_slug("other")
      ingest!(slug, upd(moves: ~w(e4)))
      ingest!(other, upd(moves: ~w(d4)))

      Takedown.purge(slug)
      assert LiveBoards.games(other) |> length() == 1
    end

    test "the panel's setter logs who changed the delay and refuses a stranger's slug", %{
      slug: slug
    } do
      {:ok, _} = Snapshots.ingest(put_in(SnapshotPayloads.swiss(), ["tournament", "slug"], slug))
      actor = %{email: "moderator@example.invalid"}

      assert {:ok, 20} = Moderation.set_live_delay(slug, 20, actor)
      assert {:ok, 0} = Moderation.set_live_delay(slug, 0, actor)
      assert {:error, :invalid} = Moderation.set_live_delay(slug, -5, actor)
      assert {:error, :not_found} = Moderation.set_live_delay("no-such-tournament", 5, actor)

      assert [
               %{action: "live_delay", details: %{"from" => 20, "to" => 0}},
               %{details: %{"from" => 0, "to" => 20}}
             ] =
               Moderation.list_actions(%{target: slug})
    end
  end
end
