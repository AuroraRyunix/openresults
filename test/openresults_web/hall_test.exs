defmodule OpenResultsWeb.HallTest do
  @moduledoc """
  The hall display's rules, without a socket: the settings as they travel,
  what each view holds, and when the cycle holds on the pairings. The
  LiveView that draws them is `OpenResultsWeb.HallLiveTest`.
  """

  use ExUnit.Case, async: true

  alias OpenResults.SnapshotPayloads
  alias OpenResultsWeb.Hall

  defp with_hall(payload, hall), do: put_in(payload, ["tournament", "hall"], hall)

  defp build(payload), do: Hall.build(payload, Hall.settings(payload))

  # Round 5 of the swiss fixture, its results taken out: freshly paired.
  defp freshly_paired do
    update_in(SnapshotPayloads.swiss(), ["rounds"], fn rounds ->
      Enum.map(rounds, fn
        %{"number" => 5} = round ->
          Map.update!(round, "boards", fn boards ->
            Enum.map(boards, &Map.put(&1, "result", nil))
          end)

        round ->
          round
      end)
    end)
  end

  describe "settings/2" do
    test "an OpenPairings that sends no hall settings gets the defaults" do
      settings = Hall.settings(SnapshotPayloads.swiss())

      assert settings.views == [:pairings, :names, :results, :standings, :live]
      assert settings.page_seconds == 15
      assert settings.standings_top == 10
      assert settings.hold_new_round?
      assert settings.announcement == nil
    end

    test "reads what the arbiter chose" do
      settings =
        SnapshotPayloads.swiss()
        |> with_hall(%{
          "pairings" => true,
          "names" => false,
          "results" => false,
          "standings" => true,
          "standings_top" => 20,
          "page_seconds" => 30,
          "hold_new_round" => false,
          "announcement" => "  Round 6 starts at 14:00.\nPhones off.  "
        })
        |> Hall.settings()

      assert settings.views == [:pairings, :standings, :live, :announcement]
      assert settings.page_seconds == 30
      assert settings.standings_top == 20
      refute settings.hold_new_round?
      assert settings.announcement == "Round 6 starts at 14:00.\nPhones off."
    end

    test "ignores values out of range or of the wrong shape" do
      settings =
        SnapshotPayloads.swiss()
        |> with_hall(%{
          "page_seconds" => 1,
          "standings_top" => "lots",
          "announcement" => "   ",
          "pairings" => "no"
        })
        |> Hall.settings()

      assert settings.page_seconds == 15
      assert settings.standings_top == 10
      assert settings.announcement == nil
      assert :pairings in settings.views
    end

    test "?views= narrows the arbiter's views but never adds one" do
      payload = with_hall(SnapshotPayloads.swiss(), %{"standings" => false})

      assert Hall.settings(payload, [:names, :standings]).views == [:names]
    end
  end

  describe "parse_views/1" do
    test "reads known names and nothing else" do
      assert Hall.parse_views("names, Standings,bogus") == [:names, :standings]
      assert Hall.parse_views("bogus") == nil
      assert Hall.parse_views(nil) == nil
    end
  end

  describe "build/2" do
    test "the current round is the newest published one" do
      data = build(SnapshotPayloads.swiss())

      assert data.round.number == 5
      assert data.round.final?
      assert length(data.boards) == 5
      assert data.progress == {5, 5}
    end

    test "the name list is alphabetical, accents and all, with the board and colour" do
      names = build(SnapshotPayloads.swiss()).names

      assert Enum.map(names, & &1.name) == [
               "Ångström, Åsa",
               "Björnsson, Sævar",
               "De Smet, Jean-Baptiste",
               "Đurić, Nikola",
               "Łukasiewicz, Paweł",
               "Müller, Jörg",
               "Nguyễn, Thị Hà",
               "Ó Súilleabháin, Séamus",
               "Ștefănescu, Ioana",
               "Vandenberghe, Françoise"
             ]

      assert %{board: "1", colour: :black} = Enum.find(names, &(&1.name == "Müller, Jörg"))
    end

    test "honours the arbiter's display ticks" do
      payload =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "display", "rating"], false)
        |> put_in(["tournament", "display", "title"], false)

      data = build(payload)

      assert Enum.all?(data.boards, &(is_nil(&1.white.rating) and is_nil(&1.white.title)))
      assert Enum.all?(data.standings.rows, &is_nil(&1.person.rating))
    end

    test "no round, names or results when round pages are withheld" do
      data =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "display", "pairings"], false)
        |> build()

      assert data.round == nil
      assert data.boards == [] and data.names == [] and data.reported == []
    end

    test "no standings when they are withheld, or before there are any" do
      assert SnapshotPayloads.swiss()
             |> put_in(["tournament", "display", "standings"], false)
             |> build()
             |> Map.get(:standings) == nil

      assert SnapshotPayloads.swiss()
             |> put_in(["standings", "rows"], [])
             |> build()
             |> Map.get(:standings) == nil
    end

    test "withheld results are not results" do
      payload =
        update_in(SnapshotPayloads.swiss(), ["rounds"], fn rounds ->
          Enum.map(rounds, &Map.put(&1, "results_public", false))
        end)

      data = build(payload)

      refute data.results?
      assert data.reported == []
      assert Enum.all?(data.boards, &is_nil(&1.result))
    end

    test "the standings stop at the top N" do
      data =
        SnapshotPayloads.swiss()
        |> with_hall(%{"standings_top" => 3})
        |> build()

      assert length(data.standings.rows) == 3
    end
  end

  describe "the cycle" do
    test "every view with something to show, a page each" do
      payload = SnapshotPayloads.swiss()
      data = build(payload)

      assert Hall.slides(data, Hall.settings(payload)) ==
               [pairings: 0, names: 0, results: 0, standings: 0]
    end

    test "a freshly paired round holds on the pairings and the names" do
      payload = with_hall(freshly_paired(), %{"announcement" => "Welcome"})
      settings = Hall.settings(payload)
      data = Hall.build(payload, settings)

      assert Hall.hold?(data, settings)
      assert Hall.slides(data, settings) == [pairings: 0, names: 0, announcement: 0]
    end

    test "unless the arbiter turned the hold off" do
      payload = with_hall(freshly_paired(), %{"hold_new_round" => false})
      settings = Hall.settings(payload)
      data = Hall.build(payload, settings)

      refute Hall.hold?(data, settings)
      assert {:standings, 0} in Hall.slides(data, settings)
    end

    test "long lists run over several pages" do
      data = build(SnapshotPayloads.swiss())
      many = Enum.map(1..30, &%{id: "name-#{&1}", name: "Player #{&1}"})
      data = %{data | names: many}

      assert Hall.count(data, :names) == 2
      assert length(Hall.rows(data, {:names, 1})) == 30 - Hall.names_per_page()
      assert Hall.name_range(Hall.rows(data, {:names, 0})) == {"Pl", "Pl"}
    end
  end

  describe "arrivals and the latest results" do
    test "results already in are not new; results that arrive are, newest first" do
      payload = freshly_paired()
      settings = Hall.settings(payload)
      first = Hall.build(payload, settings)
      arrivals = Hall.arrivals(%{}, first, 1_000, true)

      assert arrivals == %{}

      later =
        update_in(payload, ["rounds"], fn rounds ->
          Enum.map(rounds, fn
            %{"number" => 5} = round ->
              update_in(round, ["boards"], fn [b1, b2 | rest] ->
                [Map.put(b1, "result", "1-0"), Map.put(b2, "result", "0-1") | rest]
              end)

            round ->
              round
          end)
        end)

      data = Hall.build(later, settings)
      arrivals = Hall.arrivals(arrivals, data, 2_000, false)

      [newest | _] = Hall.latest(data, arrivals, 2_500)
      assert newest.fresh?
      assert length(Hall.latest(data, arrivals, 2_500)) == 2
    end
  end
end
