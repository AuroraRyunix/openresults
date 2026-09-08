defmodule OpenResultsWeb.Layouts do
  @moduledoc """
  The one layout this app has.

  The scaffold's `app/1` wrapper, its flash group and its theme toggle are
  gone. Flash needs a session, which the read path does not fetch, and the
  theme toggle needs JavaScript to remember a choice - the stylesheet honours
  `prefers-color-scheme` instead, which the phone has already decided.

  The four functions below all read `assigns` defensively. The layout renders
  for pages that set nothing but a title and, in principle, for whatever a
  future error page hands it; a missing assign has to produce a plainer head,
  never an exception on the way out of a request that had already succeeded.
  """
  use OpenResultsWeb, :html

  embed_templates "layouts/*"

  @site "OpenResults"

  @doc """
  The page's title, and the site's after it.

  One function rather than two, because `<title>` and `og:title` disagreeing
  would mean the tab and the shared link named different things.
  """
  def title(assigns) do
    [assigns[:page_title], @site] |> Enum.reject(&is_nil/1) |> Enum.join(" - ")
  end

  @doc """
  The sentence a share preview shows under the title, or `nil`.

  `nil` is a real answer: a page with nothing worth saying about it is better
  off with no description than with a generic one, which search engines and
  chat apps both treat as noise.
  """
  def description(assigns) do
    case assigns[:page_description] do
      text when is_binary(text) and text != "" -> text
      _absent -> nil
    end
  end

  @doc """
  This page's own address, for `og:url`.

  Built from the endpoint's configured host rather than from the request's
  `Host` header, which matters more here than it looks: a rendered page is
  cached and handed to later readers verbatim, so anything in it that varied
  by request would be served to somebody it was not built for.
  """
  def canonical_url(assigns) do
    case assigns[:conn] do
      %Plug.Conn{} = conn -> Phoenix.Controller.current_url(conn)
      _no_conn -> nil
    end
  end

  @doc "The locale this page rendered in, for `<html lang>` and `og:locale`."
  def locale(assigns) do
    case assigns[:locale] do
      code when is_binary(code) -> code
      _absent -> OpenResultsWeb.Locale.default()
    end
  end
end
