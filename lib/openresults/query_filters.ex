defmodule OpenResults.QueryFilters do
  @moduledoc """
  The two pieces of filter handling every moderation list shares: a `LIKE`
  pattern that treats the searched text as text, and `limit`/`offset`.
  """

  import Ecto.Query, warn: false

  @doc """
  `%text%`, with `%`, `_` and the escape character itself escaped, for a
  `LIKE ? ESCAPE '\\'`. Without the escaping, searching for `50%` would match
  everything that starts with 50.
  """
  @spec like_pattern(String.t()) :: String.t()
  def like_pattern(text) do
    escaped =
      text
      |> String.trim()
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end

  @doc "Applies `limit` and `offset` from a filter map, when they are sensible integers."
  @spec paginate(Ecto.Query.t(), map()) :: Ecto.Query.t()
  def paginate(query, filters) do
    query
    |> maybe_limit(Map.get(filters, :limit))
    |> maybe_offset(Map.get(filters, :offset))
  end

  defp maybe_limit(query, limit) when is_integer(limit) and limit > 0, do: limit(query, ^limit)
  defp maybe_limit(query, _none), do: query

  defp maybe_offset(query, offset) when is_integer(offset) and offset > 0,
    do: offset(query, ^offset)

  defp maybe_offset(query, _none), do: query
end
