defmodule OpenResultsWeb.Pieces do
  @moduledoc """
  The piece sets the live-board pages can draw with, and nothing about how.

  Each set is one static SVG sprite under `priv/static/pieces/` holding twelve
  `<symbol>`s (`wK`, `bQ`, ...), placed on the board with
  `<use href="/pieces/<set>.svg#wK">`. The art is third-party and licensed on
  its own terms, shipped as plain files beside the licence it came with
  (`priv/static/pieces/<set>/LICENSE`) and never compiled into
  this code. See `NOTICE`.

  A viewer's choice is remembered in the browser (`localStorage`, like the
  colour theme), not in a cookie: the site sets exactly one cookie and says
  so in its terms. The page learns it from the LiveView connect params, from
  `?pieces=` in the URL (which wins - a hall screen has no picker), or from
  the picker's event. A set this site does not ship (any more) is the default.
  """

  @default "cburnett"

  # In the order the picker shows them. `{key, name, designer}`.
  @sets [
    {"cburnett", "Cburnett", "Colin M.L. Burnett"},
    {"chessnut", "Chessnut", "Alexis Luengas"}
  ]

  @doc "`{key, name, designer}` for each set, default first."
  def sets, do: @sets

  def default, do: @default

  @doc "The set a value names, or nil when it names none we ship."
  def known(value) when is_binary(value) do
    if Enum.any?(@sets, fn {key, _name, _designer} -> key == value end), do: value
  end

  def known(_other), do: nil

  @doc "A value as a set we ship; the default for anything else."
  def normalize(value), do: known(value) || @default

  @doc """
  The set for a page: `?pieces=` first, then what the browser remembered
  (connect params; absent on the first, static render), then the default.
  """
  def choose(url_params, connect_params) do
    known(get(url_params)) || known(get(connect_params)) || @default
  end

  defp get(%{"pieces" => value}), do: value
  defp get(_none), do: nil

  @doc "The sprite file of a set."
  def sprite(set), do: "/pieces/#{normalize(set)}.svg"

  @doc "The `href` of one piece (`\"wK\"`) in a set."
  def href(set, piece), do: sprite(set) <> "#" <> piece
end
