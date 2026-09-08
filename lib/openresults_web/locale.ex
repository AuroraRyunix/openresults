defmodule OpenResultsWeb.Locale do
  @moduledoc """
  Which language a page renders in.

  ## Where the choice comes from

  In order: an explicit `?lang=` on the URL, then the preference cookie that
  such a request leaves behind, then the browser's `accept-language` header,
  then English.

  The header carries most of the weight here, and more than it does in the
  arbiter's app. Everybody reading these pages is a player or a spectator
  with no account and no settings screen, so the only thing that can speak
  for them is what their browser already says. A Belgian visitor whose
  browser asks for `nl-BE` gets Dutch without touching anything.

  Region subtags are matched loosely: `nl-BE`, `nl-NL` and `nl` all resolve
  to `nl`, and `fr-BE` to `fr`. Chess vocabulary does not differ between
  Flanders and the Netherlands, or between Wallonia and France, enough to
  justify a second catalogue.

  ## Why the override is a query parameter and not a session

  The arbiter's app keeps the choice in the session. This site has none, and
  its absence is a feature the router argues for at length: no `fetch_session`
  means no Set-Cookie on any read, which is why these pages need no consent
  banner. A language picker is not a reason to give that up for every reader.

  So the override travels in the URL. Three consequences, all of them wanted:

    * A reader who never touches the picker is served exactly what they are
      served today, cookie and all - which is to say, without one.
    * `?lang=fr` is a link. Pasting the French standings into a French club's
      WhatsApp group works, which is how people actually find this site.
    * It survives an iframe. Club sites embed these pages (see
      `OpenResultsWeb.Framing`), and a cookie set in a third-party frame is
      not sent back by a browser with sensible defaults - so a cookie-only
      picker would appear broken in exactly the place embedding is for.

  The cookie is a convenience laid on top: written only by a request that
  already carried an explicit `?lang=`, so that the reader's next click keeps
  the language without the parameter having to be threaded through every link
  on the page. Losing it costs a fallback to `accept-language`, never a
  failure.

  ## Adding a language

  Add it to `@locales` with its own name in its own language, run
  `mix gettext.extract --merge`, translate `priv/gettext/<code>/LC_MESSAGES`,
  and it appears in the picker.
  """

  # {code, endonym}. The label is the language's name IN that language, not
  # in English: someone who needs Dutch is looking for "Nederlands", and
  # cannot necessarily read the word "Dutch" to find it.
  @locales [
    {"en", "English"},
    {"nl", "Nederlands"},
    {"fr", "Français"}
  ]

  @default "en"
  @param "lang"
  @cookie "openresults_locale"

  # A year. Long enough that a spectator who set it at one tournament still
  # has it at the next one, and it holds nothing but two letters chosen in
  # the open.
  @cookie_max_age 365 * 24 * 60 * 60

  @doc "The locale rendered when nothing else answers."
  def default, do: @default

  @doc "The query parameter carrying an explicit choice."
  def param, do: @param

  @doc "The cookie an explicit choice leaves behind."
  def cookie, do: @cookie

  @doc "How long that cookie lives, in seconds."
  def cookie_max_age, do: @cookie_max_age

  @doc "Every locale the site can render, as `{code, endonym}`."
  def locales, do: @locales

  @doc "Just the codes."
  def codes, do: Enum.map(@locales, &elem(&1, 0))

  @doc "The endonym for a code, or the code itself if it is not one we ship."
  def label(code) do
    case List.keyfind(@locales, code, 0) do
      {_code, name} -> name
      nil -> code
    end
  end

  @doc "Whether this is a locale the site actually ships."
  def known?(code), do: code in codes()

  @doc """
  The Open Graph locale for a code - `language_TERRITORY`, which is the only
  shape Facebook and the rest read.

  The territories are Belgian for Dutch and French because that is who reads
  this site; the catalogues themselves are not regional, and nothing else in
  the app knows about a region at all.
  """
  def og_locale("nl"), do: "nl_BE"
  def og_locale("fr"), do: "fr_BE"
  def og_locale("en"), do: "en_GB"
  def og_locale(_unknown), do: og_locale(@default)

  @doc """
  Resolves a locale from the three things that can name one.

  Every argument is attacker-controlled and every one of them may be `nil`,
  junk, or a header a fuzzer wrote. Nothing here may raise: a malformed
  `accept-language` is a reason to render English, never a reason to 500 a
  public page.
  """
  def resolve(param, cookie, accept_language) do
    from_value(param) || from_value(cookie) || from_header(accept_language) || @default
  end

  defp from_value(value) when is_binary(value) do
    code = base(value)
    if known?(code), do: code
  end

  defp from_value(_absent_or_wrong_shape), do: nil

  # `accept-language: nl-BE,nl;q=0.9,en;q=0.8` - take the highest-quality
  # entry we can actually serve. Quality values order the list and nothing
  # else; a malformed one sorts last rather than raising.
  defp from_header(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_code, q} -> -q end)
    |> Enum.find_value(fn {code, _q} -> if known?(code), do: code end)
  end

  defp from_header(_absent_or_wrong_shape), do: nil

  defp parse_entry(entry) do
    case String.split(entry, ";") do
      [tag] -> {base(tag), 1.0}
      [tag, q] -> {base(tag), quality(q)}
      _not_an_entry -> nil
    end
  end

  # "nl-BE" -> "nl". Region is dropped deliberately; see the moduledoc.
  defp base(tag) do
    tag |> String.trim() |> String.downcase() |> String.split("-") |> hd()
  end

  defp quality("q=" <> value) do
    case Float.parse(String.trim(value)) do
      {q, _rest} -> q
      :error -> 0.0
    end
  end

  defp quality(_other), do: 0.0

  @doc """
  This same page in another language.

  Keeps every other parameter - `?display=1` above all, since the picker is
  on the projector view too - and sorts them, so one page in one language is
  one URL and therefore one entry in the page cache rather than several.
  """
  def switch_path(conn, code) do
    query =
      conn
      |> query_params()
      |> Map.put(@param, code)
      |> Enum.sort()
      |> URI.encode_query()

    conn.request_path <> "?" <> query
  end

  defp query_params(%Plug.Conn{query_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp query_params(%Plug.Conn{query_params: params}) when is_map(params), do: params
  defp query_params(_not_a_conn), do: %{}
end
