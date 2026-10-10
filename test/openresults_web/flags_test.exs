defmodule OpenResultsWeb.FlagsTest do
  @moduledoc """
  Federation flags: the table from FIDE's codes to the files, the files
  themselves (plain SVG, licensed, within budget, served with a long cache),
  and the rule for when a page draws one - only when the snapshot's
  `display.flags` is `true`, never where the federation is hidden, never for
  a code with no country behind it.
  """

  use OpenResultsWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import OpenResults.PublicPublishingFixtures, only: [unique_slug: 1]

  alias OpenResults.LiveBoards
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.Flags
  alias OpenResultsWeb.Tournament

  @dir "priv/static/flags"

  defp files do
    Application.app_dir(:openresults, @dir)
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".svg"))
  end

  # The swiss fixture (which asks for flags) with round 5 still to play, so
  # the live pages have boards to show.
  defp publish!(tweak \\ & &1) do
    slug = unique_slug("flags")

    payload =
      SnapshotPayloads.swiss()
      |> put_in(["tournament", "slug"], slug)
      |> update_in(["rounds"], fn rounds ->
        Enum.map(rounds, fn
          %{"number" => 5} = round ->
            Map.update!(round, "boards", fn boards ->
              Enum.map(boards, &Map.put(&1, "result", nil))
            end)

          round ->
            round
        end)
      end)
      |> tweak.()

    {:ok, _} = Snapshots.ingest(payload)
    slug
  end

  defp without_flags(payload),
    do: update_in(payload, ["tournament", "display"], &Map.delete(&1, "flags"))

  defp display(payload, key, value), do: put_in(payload, ["tournament", "display", key], value)

  defp doc(conn, path), do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  describe "the table" do
    test "FIDE's own codes, not ISO's" do
      assert Flags.path("GER") == "/flags/de.svg"
      assert Flags.path("NED") == "/flags/nl.svg"
      assert Flags.path("SUI") == "/flags/ch.svg"
      assert Flags.path("BEL") == "/flags/be.svg"
      assert Flags.path("ENG") == "/flags/gb-eng.svg"
      assert Flags.path("SCO") == "/flags/gb-sct.svg"
      assert Flags.path("WLS") == "/flags/gb-wls.svg"
      assert Flags.path(" bel ") == "/flags/be.svg"
    end

    test "no flag for the FIDE flag, an unknown code or junk" do
      for code <- ["FID", "XXX", "DE", "", "../../etc/passwd", nil, 7, %{}] do
        assert Flags.path(code) == nil
      end
    end

    test "nothing when flags are off, whatever the code" do
      assert Flags.path("BEL", true) == "/flags/be.svg"
      assert Flags.path("BEL", false) == nil
      assert Flags.path("BEL", nil) == nil
    end

    test "every code has its file, and every file a code" do
      shipped = files() |> Enum.map(&Path.rootname/1) |> Enum.sort()
      mapped = Flags.table() |> Map.values() |> Enum.uniq() |> Enum.sort()

      assert mapped == shipped
      assert Enum.all?(Map.keys(Flags.table()), &(&1 =~ ~r/^[A-Z]{3}$/))
    end
  end

  describe "the files" do
    test "are plain SVG: no script, no handler, nothing fetched from elsewhere" do
      dir = Application.app_dir(:openresults, @dir)

      for file <- files() do
        svg = File.read!(Path.join(dir, file))

        assert String.starts_with?(svg, "<svg "), file
        refute svg =~ ~r/<\s*(script|foreignObject|image|iframe|object|embed|style|a)\b/i, file
        refute svg =~ ~r/\son[a-z]+\s*=/i, file
        refute svg =~ ~r/<!--|<!DOCTYPE|<!ENTITY/i, file
        refute svg =~ ~r/javascript:|data:/i, file

        for [_all, target] <- Regex.scan(~r/href\s*=\s*"([^"]*)"/, svg) do
          assert String.starts_with?(target, "#"), file
        end

        refute svg =~ ~r/(?<!xmlns=")(?<!xmlns:xlink=")https?:\/\//, file
      end
    end

    test "fit the budget" do
      dir = Application.app_dir(:openresults, @dir)
      total = files() |> Enum.map(&File.stat!(Path.join(dir, &1)).size) |> Enum.sum()

      assert total < 1_500_000
    end

    test "the licence ships beside them and the NOTICE says whose they are" do
      licence = File.read!(Path.join(Application.app_dir(:openresults, @dir), "LICENSE"))
      assert licence =~ "MIT License"
      assert licence =~ "Panayiotis Lipiridis"

      notice = File.read!("NOTICE")
      assert notice =~ "flag-icons"
      assert notice =~ "priv/static/flags/LICENSE"
    end

    test "are served as images with a long cache", %{conn: conn} do
      conn = get(conn, "/flags/be.svg")
      assert response(conn, 200) =~ "<svg"
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "image/svg+xml"
      assert [cache] = get_resp_header(conn, "cache-control")
      assert cache =~ "max-age=2592000"

      assert conn |> recycle() |> get("/flags/zz.svg") |> response(404)
    end
  end

  describe "the component" do
    defp fed(code, on) do
      assigns = %{code: code, on: on}

      rendered_to_string(~H"""
      <Flags.fed code={@code} on={@on} />
      """)
    end

    test "a flag before the code: decorative, lazy, with its size stated" do
      document = LazyHTML.from_fragment(fed("NED", true))

      assert count(
               document,
               ~s(.fed img.flag[src="/flags/nl.svg"][alt=""][loading="lazy"][width="20"][height="15"])
             ) == 1

      assert LazyHTML.text(document) =~ "NED"
    end

    test "the code alone when flags are off, when there is no flag, and a dash for nobody" do
      refute fed("NED", false) =~ "<img"
      assert fed("NED", false) =~ "NED"

      refute fed("FID", true) =~ "<img"
      assert fed("FID", true) =~ "FID"

      refute fed(nil, true) =~ "<img"
      assert fed(nil, true) =~ "-"
    end
  end

  describe "Tournament.flags?/1" do
    test "absent means off, and only true means on" do
      payload = SnapshotPayloads.swiss()

      assert Tournament.flags?(payload)
      refute Tournament.flags?(without_flags(payload))
      refute Tournament.flags?(display(payload, "flags", false))
      refute Tournament.flags?(display(payload, "flags", "yes"))
      refute Tournament.flags?(Map.update!(payload, "tournament", &Map.delete(&1, "display")))
    end

    test "off where the federation is hidden: there is no code to draw one for" do
      refute Tournament.flags?(display(SnapshotPayloads.swiss(), "federation", false))
    end
  end

  describe "a player's card" do
    test "draws a flag beside each opponent's federation", %{conn: conn} do
      slug = publish!()
      document = doc(conn, ~p"/t/#{slug}/player/1")

      assert count(document, ~s(td .fed img.flag[alt=""][loading="lazy"])) > 0

      for src <- document |> LazyHTML.query("img.flag") |> LazyHTML.attribute("src") do
        assert src =~ ~r{^/flags/[a-z-]+\.svg$}
      end
    end

    test "draws none for a snapshot that does not mention flags", %{conn: conn} do
      slug = publish!(&without_flags/1)
      document = doc(conn, ~p"/t/#{slug}/player/1")

      assert count(document, "img.flag") == 0
      # The codes are still there.
      assert count(document, "td .fed") > 0
    end

    test "draws none when the arbiter switched them off, or hid the federations", %{conn: conn} do
      off = publish!(&display(&1, "flags", false))
      assert conn |> doc(~p"/t/#{off}/player/1") |> count("img.flag") == 0

      hidden = publish!(&display(&1, "federation", false))
      document = doc(conn, ~p"/t/#{hidden}/player/1")
      assert count(document, "img.flag") == 0
      assert count(document, "td .fed") == 0
    end

    test "a player under the FIDE flag keeps the code and gets no picture", %{conn: conn} do
      slug =
        publish!(fn payload ->
          update_in(payload["players"], fn players ->
            Enum.map(players, &Map.put(&1, "federation", "FID"))
          end)
        end)

      document = doc(conn, ~p"/t/#{slug}/player/1")
      assert count(document, "img.flag") == 0
      assert document |> LazyHTML.query("td .fed") |> LazyHTML.text() =~ "FID"
    end
  end

  describe "the live boards" do
    defp report(slug, board, moves) do
      assert {:ok, _} =
               LiveBoards.ingest(slug, %{"round" => 5, "board" => board, "moves" => moves})
    end

    test "the broadcast's player bars carry the flag beside the code", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4 e5))

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")

      assert has_element?(view, ~s(#lb-bar-white .lb-fed img.flag[alt=""][loading="lazy"]))
      assert has_element?(view, ~s(#lb-bar-black .lb-fed img.flag[alt=""]))
    end

    test "an All boards tile has room for the flag only, so the code is its text", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4 e5))

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")

      assert has_element?(view, "#live-5-1 .lb-name img.flag[loading=lazy]")
      refute has_element?(view, ~s(#live-5-1 .lb-name img.flag[alt=""]))
    end

    test "a projector tile carries it before the name", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4 e5))

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector?boards=1")

      assert has_element?(view, "#proj-1-white-name img.flag")
      assert has_element?(view, "#proj-1-black-name img.flag")
    end

    test "none of them draws one for a snapshot that does not mention flags", %{conn: conn} do
      slug = publish!(&without_flags/1)
      report(slug, 1, ~w(e4 e5))

      for path <- ["/live/5/1", "/live/5/all", "/live/5/projector?boards=1"] do
        {:ok, view, _html} = live(conn, "/t/#{slug}" <> path)
        refute has_element?(view, "img.flag"), path
      end
    end
  end

  describe "the hall display" do
    test "a player's flag travels with the federation, and not without the tick" do
      on = SnapshotPayloads.swiss()
      off = without_flags(on)

      assert flags_in(OpenResultsWeb.Hall.build(on, OpenResultsWeb.Hall.settings(on))) != []
      assert flags_in(OpenResultsWeb.Hall.build(off, OpenResultsWeb.Hall.settings(off))) == []
    end

    # Every `flag:` value anywhere in what the hall display is given.
    defp flags_in(%{flag: flag} = map) when is_binary(flag),
      do: [flag | flags_in(Map.delete(map, :flag))]

    defp flags_in(%_struct{}), do: []
    defp flags_in(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&flags_in/1)
    defp flags_in(list) when is_list(list), do: Enum.flat_map(list, &flags_in/1)
    defp flags_in(_other), do: []
  end
end
