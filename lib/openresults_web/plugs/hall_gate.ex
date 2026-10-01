defmodule OpenResultsWeb.Plugs.HallGate do
  @moduledoc """
  The hall display's 404, answered before the LiveView renders anything.

  A slug nothing published under and a hidden tournament get the page the
  standings get for them - word for word the same document, so the hall URL
  cannot be used to tell a hidden tournament from one that never existed (see
  `OpenResultsWeb.VisibilityTest`). Without this the LiveView would render a
  200 with an empty screen, which is right for a tournament hidden WHILE a
  screen shows it, and wrong as the answer to a fresh request.

  Reads through `OpenResults.Tournaments.public_latest/1`, the same door as
  every public page. Only on the hall's route: the other pages ask the same
  question in their controllers.
  """

  use Gettext, backend: OpenResultsWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias OpenResults.Tournaments
  alias OpenResultsWeb.Meta

  def init(opts), do: opts

  def call(%Plug.Conn{params: %{"slug" => slug}} = conn, _opts) when is_binary(slug) do
    case Tournaments.public_latest(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: OpenResultsWeb.TournamentHTML)
        |> render(:not_found,
          page_title: gettext("Not found"),
          page_description: Meta.not_found(),
          message: gettext("No tournament has published under %{slug}.", slug: slug),
          back: "/"
        )
        |> halt()

      _snapshot ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
