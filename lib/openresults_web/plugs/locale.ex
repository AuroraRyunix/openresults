defmodule OpenResultsWeb.Plugs.Locale do
  @moduledoc """
  Decides which language this request renders in, before anything renders.

  Runs on the `:browser` pipeline and therefore ahead of
  `OpenResultsWeb.Plugs.Revalidate`, which is not an ordering detail but the
  whole reason this is a plug: the revalidator builds an ETag and looks in
  the page cache with it, and both have to know the language first. A locale
  resolved after that point would be a locale the cache had already ignored.

  ## What it puts on the response

  `vary: accept-language, cookie` - because the two things this reads are a
  request header and a cookie, and any cache in front of us that does not
  know that will hand one reader another reader's language. The read pages
  are already `private, no-cache`, so no shared cache should be holding them
  at all; this says so a second time, in the header that browsers and
  intermediaries actually consult.

  A `Set-Cookie` only where the reader asked for one. A request carrying an
  explicit `?lang=` leaves the preference behind so the next click keeps the
  language; every other request on this site still answers without a cookie,
  which is the property the router's pipeline is built around.
  """
  import Plug.Conn

  alias OpenResultsWeb.Locale

  def init(opts), do: opts

  def call(conn, _opts) do
    # Both explicitly, rather than trusting the router to have done it: this
    # plug reads a cookie and a query parameter, and a plug that depends on
    # somebody else having fetched them is a plug that breaks when it is
    # moved.
    conn = conn |> fetch_cookies() |> fetch_query_params()

    chosen = conn.query_params[Locale.param()]

    locale =
      Locale.resolve(
        chosen,
        conn.cookies[Locale.cookie()],
        conn |> get_req_header("accept-language") |> List.first()
      )

    Gettext.put_locale(OpenResultsWeb.Gettext, locale)

    conn
    |> put_resp_header("vary", "accept-language, cookie")
    |> assign(:locale, locale)
    |> remember(chosen, locale)
  end

  # Only when the URL named a language we ship. A junk `?lang=xx` falls back
  # to the header like any other request and must not overwrite a choice the
  # reader made earlier.
  defp remember(conn, chosen, locale) when is_binary(chosen) do
    if Locale.known?(String.downcase(chosen)) do
      put_resp_cookie(conn, Locale.cookie(), locale,
        max_age: Locale.cookie_max_age(),
        http_only: true,
        same_site: "Lax",
        secure: conn.scheme == :https
      )
    else
      conn
    end
  end

  defp remember(conn, _no_choice, _locale), do: conn
end
