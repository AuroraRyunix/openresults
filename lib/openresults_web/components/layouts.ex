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

  @doc """
  The operator's notice - see `OpenResults.PublicNotice`. `notice` is what
  `OpenResultsWeb.Plugs.PublicNotice` assigned: `%{text, lang, level}`.

  A `role="note"` with a name, deliberately not a live region: it is on the
  page when the page loads and says the same thing on every page, so
  announcing it on each would be noise. Plain text, escaped like any other
  assign. The admin panel renders this same component as its preview.
  """
  attr :notice, :map, required: true
  attr :id, :string, default: "public-notice"

  def public_notice(assigns) do
    ~H"""
    <div
      id={@id}
      class={["public-notice", "public-notice-#{@notice.level}"]}
      role="note"
      aria-label={gettext("Notice")}
    >
      <p lang={@notice.lang}>{@notice.text}</p>
    </div>
    """
  end

  @doc """
  A fingerprint of the refreshed region's HTML, for `data-version`.

  The refresher decides "did this page change" by comparing this, not the
  region's markup. The markup in the browser is never the markup the server
  sent: the filter bar's script marks its form, closes the phone disclosure
  and hides rows before the refresher ever runs, so comparing markup found a
  change on every poll - replacing the region, re-announcing "updated just
  now" and resetting what the reader had opened every 10 to 20 seconds.

  A digest of the content rather than the snapshot id: the region is what
  gets swapped, so the region is what must be compared. Not a secret and not
  an ETag - identical HTML gives an identical value on any node.

  Only on a page that answered 200. The refresher never swaps anything else
  in, and an error page must stay byte-identical whichever slug it was asked
  for (see `OpenResultsWeb.VisibilityTest`) - a digest over content that
  echoes the slug would not be.
  """
  def region_version(assigns) do
    case assigns[:conn] do
      %Plug.Conn{status: status} when status in [nil, 200] ->
        :crypto.hash(:sha256, Phoenix.HTML.Safe.to_iodata(assigns[:inner_content]))
        |> binary_part(0, 12)
        |> Base.url_encode64(padding: false)

      _other ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Whether this page was asked for as an embed, with `?embed=1`.

  The same document with the site's own chrome taken off - no masthead, no
  language or theme picker, no filter bar, no footer beyond one link back -
  so a club can put its standings or the current round in an iframe on its
  own site and have it read as part of that site. Picky about the value for
  the reason `?display=1` is: `?embed=` left blank is the ordinary page.

  Read from the query string, which is part of the page cache's key and the
  ETag (see `OpenResultsWeb.Plugs.Revalidate`), so an embed and the full
  page are cached as the two different documents they are.
  """
  def embed?(assigns) do
    case assigns[:conn] do
      %Plug.Conn{query_params: %{"embed" => value}} -> value in ["1", "true"]
      _other -> false
    end
  end

  @doc "The page wrapper's classes: the projector view and the embed each restyle it."
  def page_class(assigns) do
    ["page", assigns[:display?] && "projector-mode", embed?(assigns) && "embed-mode"]
  end

  @doc """
  This page's address without `embed`, for the one link an embed keeps: the
  way out to the full page.
  """
  def full_page_path(assigns) do
    case assigns[:conn] do
      %Plug.Conn{request_path: path, query_params: params} when not is_struct(params) ->
        case Map.delete(params, "embed") do
          empty when map_size(empty) == 0 -> path
          rest -> path <> "?" <> URI.encode_query(rest)
        end

      _no_conn ->
        "/"
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
