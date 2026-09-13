defmodule OpenResultsWeb.Admin.Params do
  @moduledoc """
  Reading the admin panel's query strings and form fields.

  Everything arrives as text, possibly blank and possibly not what the page
  offered - a filter URL is typed and edited by hand as often as it is
  clicked. So a value is either one the page understands or `nil`, and `nil`
  means "not given". Nothing here raises, and nothing turns request text into
  an atom.
  """

  @doc "Trimmed text, or `nil` for blank or anything that is not text."
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def text(_value), do: nil

  @doc "`value` when it is one of `allowed`, otherwise `nil`."
  @spec one_of(term(), [String.t()]) :: String.t() | nil
  def one_of(value, allowed) when is_binary(value), do: if(value in allowed, do: value)
  def one_of(_value, _allowed), do: nil
end
