defmodule OpenResultsWeb.Plugs.PublicNotice do
  @moduledoc """
  Decides, once per request, which operator notice this page shows - see
  `OpenResults.PublicNotice`.

  Assigns `:public_notice`: `nil`, or `%{text, lang, level, version}` in the
  request's language. Runs on the `:browser` pipeline after
  `OpenResultsWeb.Plugs.Locale`, and so before `OpenResultsWeb.Plugs.Revalidate`,
  which builds the notice's `version` into the ETag and therefore into the
  page cache's key. The layout renders from this same assign, so the tag and
  the page always describe the same notice, even one that expires while the
  request is being served.

  An ETS read (`OpenResults.ServerSettings`) and a clock comparison: no query.
  """

  import Plug.Conn

  alias OpenResults.PublicNotice

  def init(opts), do: opts

  def call(conn, _opts) do
    case PublicNotice.current() do
      nil ->
        assign(conn, :public_notice, nil)

      notice ->
        locale = conn.assigns[:locale] || OpenResultsWeb.Locale.default()
        assign(conn, :public_notice, PublicNotice.for_locale(notice, locale))
    end
  end

  @doc "The version a response's ETag is keyed on: `nil` when no notice shows."
  @spec version(Plug.Conn.t()) :: String.t() | nil
  def version(%Plug.Conn{assigns: %{public_notice: %{version: version}}}), do: version
  def version(%Plug.Conn{assigns: %{public_notice: nil}}), do: nil

  # Mounted somewhere without this plug ahead of it: decide here, so a notice
  # can never be rendered without being in the tag.
  def version(%Plug.Conn{}), do: PublicNotice.version(PublicNotice.current())
end
