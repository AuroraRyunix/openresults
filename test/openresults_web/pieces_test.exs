defmodule OpenResultsWeb.PiecesTest do
  @moduledoc """
  The piece sets: what names one, what a board points at, and the static
  files behind it - twelve symbols per sprite, plain SVG, a licence beside
  each set, and a route that serves them.
  """

  use OpenResultsWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias OpenResultsWeb.LiveBoardsComponents
  alias OpenResultsWeb.Pieces

  @ids for colour <- ~w(w b), kind <- ~w(K Q R B N P), do: colour <> kind
  @sets ~w(cburnett chessnut)

  defp board(pieces) do
    assigns = %{pieces: pieces}

    rendered_to_string(~H"""
    <LiveBoardsComponents.board_svg
      fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
      label="start"
      set={@pieces}
    />
    """)
  end

  test "the sets are the two we ship, the default first" do
    assert Enum.map(Pieces.sets(), &elem(&1, 0)) == @sets
    assert Pieces.default() == "cburnett"
  end

  test "choose/2: the URL wins, then the browser's memory, then the default" do
    assert Pieces.choose(%{"pieces" => "chessnut"}, %{"pieces" => "cburnett"}) == "chessnut"
    assert Pieces.choose(%{}, %{"pieces" => "chessnut"}) == "chessnut"
    assert Pieces.choose(%{"pieces" => "bogus"}, %{"pieces" => "chessnut"}) == "chessnut"
    assert Pieces.choose(%{}, nil) == "cburnett"
    assert Pieces.choose(%{"pieces" => ["chessnut"]}, %{}) == "cburnett"
  end

  test "a set that is not shipped (any more) is the default, wherever it was asked for" do
    assert Pieces.known("merida") == nil
    assert Pieces.normalize("merida") == "cburnett"
    assert Pieces.choose(%{"pieces" => "merida"}, %{}) == "cburnett"
    assert Pieces.choose(%{}, %{"pieces" => "merida"}) == "cburnett"
    assert Pieces.sprite("merida") == "/pieces/cburnett.svg"
    refute File.exists?(Application.app_dir(:openresults, "priv/static/pieces/merida.svg"))
  end

  test "an unshipped sprite is not served", %{conn: conn} do
    assert conn |> get("/pieces/merida.svg") |> response(404)
  end

  test "a board uses <use> references into the chosen set, and falls back to the default" do
    html = board("chessnut")
    assert html =~ ~s(href="/pieces/chessnut.svg#wK")
    assert html =~ ~s(href="/pieces/chessnut.svg#bP")
    refute html =~ "cburnett"

    for unknown <- ["nope", "merida", "../x", "", nil] do
      html = board(unknown)
      assert html =~ ~s(href="/pieces/cburnett.svg#wQ")
      refute html =~ "chessnut"
    end
  end

  test "a board is thirty-two references, not thirty-two drawings" do
    html = board("cburnett")
    assert length(Regex.scan(~r/<use /, html)) == 32
    refute html =~ "<path"
  end

  for set <- @sets do
    test "#{set}: the sprite holds all twelve symbols and is plain SVG" do
      path = Application.app_dir(:openresults, "priv/static/pieces/#{unquote(set)}.svg")
      svg = File.read!(path)

      for id <- @ids, do: assert(svg =~ ~s(<symbol id="#{id}" viewBox=))
      assert length(Regex.scan(~r/<symbol /, svg)) == 12

      refute svg =~ ~r/<script|foreignObject|<!--|<image|<style/i
      refute svg =~ ~r/(?<!xmlns=")https?:\/\//
      refute svg =~ ~r/\b(?:on[a-z]+)\s*=/i
      assert byte_size(svg) < 60_000
    end

    test "#{set}: the licence ships beside the art" do
      dir = Application.app_dir(:openresults, "priv/static/pieces/#{unquote(set)}")
      assert File.ls!(dir) == ["LICENSE"]
      assert File.read!(Path.join(dir, "LICENSE")) =~ ~r/Burnett|Luengas/
    end

    test "#{set}: the sprite is served, cached and as an image", %{conn: conn} do
      conn = get(conn, "/pieces/#{unquote(set)}.svg")
      assert response(conn, 200) =~ ~s(id="wK")
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "image/svg+xml"
      assert [cache] = get_resp_header(conn, "cache-control")
      assert cache =~ "max-age=86400"
    end
  end

  test "the NOTICE credits both authors, and nobody whose art is not here" do
    notice = File.read!("NOTICE")

    for name <- ["Colin M.L. Burnett", "Alexis Luengas"] do
      assert notice =~ name
    end

    refute notice =~ ~r/merida/i
  end
end
