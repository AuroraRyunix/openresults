defmodule OpenResults.BigSnapshot do
  @moduledoc """
  A large open, generated: the shape of `snapshot_swiss.json`, at the size of
  the biggest field this site is meant to carry - a thousand players, nine
  rounds, four tie-break columns, three of them with their per-round working.

  For the page-weight tests (`test/openresults_web/page_weight_test.exs`),
  which hold the phone budget of the standings and pairings pages. The
  pairings are random rather than a Swiss draw and the tie-breaks are
  arithmetic on those random games, not FIDE's: what matters here is that
  every field the renderer walks is there, at a real size. Seeded, so two
  runs render byte for byte the same page.
  """

  @surnames ~w(Peeters Janssens Maes Jacobs Mertens Willems Claes Goossens Wouters Smets
               Dubois Lambert Dupont Martin Simon Laurent Leroy Müller Schmidt Novak
               Kowalski Nowak Horvat Rossi Bianchi García López Martínez Hansen Jensen
               Nielsen Andersson Johansson Virtanen Korhonen Ivanov Petrov Popescu Kovács Nagy)

  @given ~w(Jan Pieter Luc Marc Anna Sofie Lotte Emma Lucas Noah Louis Mila Elise Arthur
            Jules Victor Ilse Jörg Paweł Søren Åsa Zoë Matteo Chiara Diego Lucía Mikko Olga)

  @federations ~w(BEL NED FRA GER ENG ESP ITA POL CZE HUN ROU UKR SWE NOR DEN FIN AUT SUI
                  LUX IRL POR GRE SRB CRO SLO SVK BUL LTU LAT EST)

  @tiebreaks [
    %{"code" => "BHC1", "label" => "Buchholz Cut-1"},
    %{"code" => "BH", "label" => "Buchholz"},
    %{"code" => "SB", "label" => "Sonneborn-Berger"},
    %{"code" => "PS", "label" => "Progressive score"}
  ]

  @doc "A published swiss of `players` players and `rounds` rounds, all of them public."
  def swiss(players \\ 1000, rounds \\ 9) do
    :rand.seed(:exsss, {1000, 9, 4})

    roster = Enum.map(1..players, &player/1)
    pairings = Enum.map(1..rounds, &pair_round(&1, players))
    {points, games} = tally(pairings, players)

    %{
      "schema" => "openresults/snapshot",
      "version" => 1,
      "published_at" => "2026-10-01T18:00:00Z",
      "source" => %{"app" => "openpairings", "version" => "0.0.0-bigsnapshot"},
      "tournament" => tournament(rounds),
      "players" => roster,
      "rounds" => Enum.map(pairings, &round_payload/1),
      "standings" => standings(points, games, rounds)
    }
  end

  defp player(no) do
    surname = Enum.at(@surnames, rem(no * 7, length(@surnames)))
    given = Enum.at(@given, rem(no * 11, length(@given)))
    federation = Enum.at(@federations, rem(no * 3, length(@federations)))
    rating = 2650 - div(no * 1500, 1000) + :rand.uniform(40)

    %{
      "no" => no,
      "name" => "#{surname}, #{given}",
      "rating" => rating,
      "federation" => federation,
      "fide_id" => 1_000_000 + no,
      "club" => "#{federation} Club #{rem(no, 40) + 1}",
      "title" => title(rating),
      "category" => category(no),
      "categories" => [category(no)]
    }
  end

  defp title(rating) when rating >= 2500, do: "GM"
  defp title(rating) when rating >= 2400, do: "IM"
  defp title(rating) when rating >= 2300, do: "FM"
  defp title(_rating), do: nil

  defp category(no) when rem(no, 5) == 0, do: "U18"
  defp category(no) when rem(no, 7) == 0, do: "S65"
  defp category(_no), do: "Open"

  defp pair_round(number, players) do
    seats = Enum.shuffle(1..players)

    boards =
      seats
      |> Enum.chunk_every(2)
      |> Enum.with_index(1)
      |> Enum.map(fn {[white, black], board} ->
        {result, w, b} =
          Enum.random([{"1-0", 1.0, 0.0}, {"0-1", 0.0, 1.0}, {"1/2-1/2", 0.5, 0.5}])

        %{
          "board" => board,
          "label" => to_string(board),
          "white" => white,
          "black" => black,
          "result" => result,
          "points" => %{"white" => w, "black" => b}
        }
      end)

    %{number: number, boards: boards}
  end

  defp round_payload(%{number: number, boards: boards}) do
    %{
      "number" => number,
      "date" => Date.to_iso8601(Date.add(~D[2026-10-01], number)),
      "results_public" => true,
      "boards" => boards,
      "byes" => []
    }
  end

  # Each player's points, and their games as {round, opponent, own score}.
  defp tally(pairings, _players) do
    Enum.reduce(pairings, {%{}, %{}}, fn %{number: n, boards: boards}, acc ->
      Enum.reduce(boards, acc, fn board, {points, games} ->
        %{"white" => w, "black" => b, "points" => %{"white" => pw, "black" => pb}} = board

        points = points |> Map.update(w, pw, &(&1 + pw)) |> Map.update(b, pb, &(&1 + pb))

        games =
          games
          |> Map.update(w, [{n, b, pw}], &[{n, b, pw} | &1])
          |> Map.update(b, [{n, w, pb}], &[{n, w, pb} | &1])

        {points, games}
      end)
    end)
  end

  defp standings(points, games, rounds) do
    rows =
      points
      |> Enum.map(fn {no, pts} ->
        own = games |> Map.fetch!(no) |> Enum.sort()
        bh_parts = Enum.map(own, fn {r, opp, _s} -> part(r, opp, points[opp]) end)
        sb_parts = Enum.map(own, fn {r, opp, s} -> part(r, opp, s * points[opp]) end)
        lowest = Enum.min_by(bh_parts, & &1["value"])

        bhc1_parts =
          Enum.map(bh_parts, fn p -> if p == lowest, do: Map.put(p, "kind", "cut"), else: p end)

        bh = total(bh_parts)
        bhc1 = bh - lowest["value"]
        sb = total(sb_parts)

        ps =
          own |> Enum.scan(0.0, fn {_r, _o, s}, acc -> acc + s end) |> Enum.sum()

        %{
          "player" => no,
          "points" => pts,
          "category" => category(no),
          "tiebreaks" => [bhc1, bh, sb, ps],
          "working" => %{
            "BHC1" => %{"parts" => bhc1_parts, "total" => bhc1},
            "BH" => %{"parts" => bh_parts, "total" => bh},
            "SB" => %{"parts" => sb_parts, "total" => sb}
          }
        }
      end)
      |> Enum.sort_by(fn row -> {-row["points"], -hd(row["tiebreaks"]), row["player"]} end)
      |> Enum.with_index(1)
      |> Enum.map(fn {row, rank} -> Map.put(row, "rank", rank) end)

    %{
      "after_round" => rounds,
      "manual_incomplete" => false,
      "manual_order" => false,
      "manual_stale" => false,
      "tiebreaks_withheld" => false,
      "tiebreaks" => @tiebreaks,
      "rows" => rows
    }
  end

  defp part(round, opponent, value),
    do: %{"round" => round, "opponent" => opponent, "value" => value}

  defp total(parts), do: parts |> Enum.map(& &1["value"]) |> Enum.sum()

  defp tournament(rounds) do
    %{
      "slug" => "big-open-2026",
      "name" => "Big Open 2026",
      "city" => "Antwerp",
      "federation" => "BEL",
      "arbiter" => "A. Arbiter",
      "deputy" => nil,
      "start_date" => "2026-10-02",
      "end_date" => "2026-10-10",
      "rounds_count" => rounds,
      "system" => "swiss",
      "tempo" => "standard",
      "time_control" => "90'+30\"",
      "fide_rated" => true,
      "listed" => true,
      "match_format" => false,
      "categories" => ["Open", "U18", "S65"],
      "registration_open" => false,
      "registration" => %{"list_public" => false, "taken" => 1000},
      "scoring" => %{
        "bye" => 1.0,
        "draw" => 0.5,
        "forfeit_loss" => 0.0,
        "forfeit_win" => 1.0,
        "loss" => 0.0,
        "presence" => nil,
        "win" => 1.0
      },
      "display" => %{
        "arbiter" => true,
        "byes" => true,
        "category" => true,
        "city" => true,
        "club" => true,
        "dates" => true,
        "deputy" => true,
        "federation" => true,
        "fide_badge" => true,
        "pairing_scores" => true,
        "pairings" => true,
        "player_cards" => true,
        "rating" => true,
        "rounds_played" => false,
        "standings" => true,
        "tiebreak_working" => true,
        "tiebreaks" => true,
        "time_control" => true,
        "title" => true
      }
    }
  end
end
