defmodule OpenResultsWeb.FilterParams do
  @moduledoc """
  The filter/sort bar's own query string, parsed once and read everywhere
  else as a plain struct.

  `?category=U1800&fed=BEL&club=...&q=...&sort=rating&team=3` is the whole
  contract: six keys, every one of them optional, every one of them a
  plain string a reader can type or a link can carry. `team` is a team's
  `no` (see `docs/snapshot-schema.md`), carried as a string like every other
  key here - only `OpenResultsWeb.Tournament.Filter` compares it against one. Nothing here decides
  what a value MEANS against a particular tournament - that is
  `OpenResultsWeb.Tournament.Filter`'s job, once it has a payload to check
  the value against. This module only decides whether a value is safe to
  carry forward at all.

  ## Why this exists rather than reading `conn.params` inline

  A GET query string is the one input on this site that is not the
  arbiter's own document - it is typed by, or given to, whoever is looking
  at the page. `parse/1` is the one place that distrust lives: every value
  is bounded in length, `sort` is checked against a fixed vocabulary, and
  anything that arrives as a list (`?q[]=a&q[]=b`) or any other non-string
  shape is dropped rather than crashing `String.length/1` on it. Nothing
  downstream ever sees a raw `conn.params` value.

  Unknown values are never rejected outright - a `category` naming a
  category this tournament does not have is still a valid STRING, just one
  that will not match any row (see `Tournament.Filter.standings/2`, which
  handles that by matching nothing rather than by erroring). Only the
  SHAPE is validated here: too long, or not a string at all, is the only
  thing this module refuses.
  """

  @enforce_keys []
  defstruct category: nil, fed: nil, club: nil, q: nil, sort: "rank", team: nil

  @type t :: %__MODULE__{
          category: String.t() | nil,
          fed: String.t() | nil,
          club: String.t() | nil,
          q: String.t() | nil,
          sort: String.t(),
          team: String.t() | nil
        }

  # Well past any real category name, club name or search term - long enough
  # that nothing legitimate is ever this size, short enough that a query
  # string built entirely of `q=` junk costs nothing worth measuring. See
  # `docs/snapshot-schema.md` for the same reasoning applied to other
  # arbiter-supplied strings.
  @max_length 100

  @sort_keys ~w(rank rating name federation)

  @doc """
  Reads the five filter/sort keys out of `params` (a controller's
  `conn.params`, or any string-keyed map), silently dropping anything
  outside the bounds above.

  Never raises. A `category` that arrived as a list (a client sending
  `?category[]=a&category[]=b`), a `q` a thousand characters long, or a
  `sort` this app has never heard of all resolve to the same safe default
  as not sending the key at all - `sort` falls back to `"rank"`, the rest to
  `nil`. This is the only rule that matters for "never a 400, never an
  error page, never an unrecognised filter silently matching everything":
  a request nothing here can make sense of simply gets the unfiltered page.
  """
  @spec parse(map()) :: t()
  def parse(params) when is_map(params) do
    %__MODULE__{
      category: bounded(params["category"]),
      fed: bounded(params["fed"]),
      club: bounded(params["club"]),
      q: bounded(params["q"]),
      sort: sort(params["sort"]),
      team: bounded(params["team"])
    }
  end

  def parse(_not_a_map), do: %__MODULE__{}

  defp bounded(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> if String.length(trimmed) <= @max_length, do: trimmed, else: nil
    end
  end

  defp bounded(_not_a_string), do: nil

  defp sort(value) when value in @sort_keys, do: value
  defp sort(_absent_or_unrecognised), do: "rank"

  @doc "Whether any filter (not the sort) is set - what decides the cache bypass and the empty-state message."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{category: c, fed: f, club: cl, q: q, team: t}),
    do: not is_nil(c) or not is_nil(f) or not is_nil(cl) or not is_nil(q) or not is_nil(t)

  @doc """
  Whether `params` (raw, as `conn.query_string` would carry them) carries
  any filter/sort key at all with a value, used by
  `OpenResultsWeb.Plugs.Revalidate` to decide whether to bypass the page
  cache - see that module for why membership in this set, rather than
  `active?/1` on the parsed struct, is what it checks: a request carrying
  `sort=name` alone changes nothing about which rows show, but it DOES
  change the rendered page (the row order), so it must bypass the cache
  exactly like a real filter does.
  """
  @spec any_present?(map()) :: boolean()
  def any_present?(params) when is_map(params) do
    Enum.any?(~w(category fed club q sort team), fn key ->
      case Map.get(params, key) do
        value when is_binary(value) -> String.trim(value) != ""
        _absent_or_not_a_string -> false
      end
    end)
  end

  def any_present?(_not_a_map), do: false

  @doc """
  `filters` as a map fit for `~p"...?\#{...}"` - only the keys that differ
  from "no filter, default sort", so an unfiltered link never grows a
  `?category=&fed=&...` tail and `sort=rank` (the default) never appears in
  a URL a reader did not choose.
  """
  @spec to_params(t()) :: %{optional(String.t()) => String.t()}
  def to_params(%__MODULE__{} = filters) do
    %{
      "category" => filters.category,
      "fed" => filters.fed,
      "club" => filters.club,
      "q" => filters.q,
      "sort" => if(filters.sort != "rank", do: filters.sort),
      "team" => filters.team
    }
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Map.new()
  end
end
