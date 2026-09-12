defmodule OpenResultsWeb.Admin.Confirmation do
  @moduledoc """
  How a destructive admin action is asked for: a confirmation page, then a
  CSRF-checked POST. No JavaScript, no `confirm()` dialog.

  ## The pattern

  One path, two verbs. GET asks, POST does:

      # router, inside the /admin scope
      get "/tournaments/:slug/delete", TournamentController, :confirm_delete
      post "/tournaments/:slug/delete", TournamentController, :delete

      # controller
      plug OpenResultsWeb.Admin.Confirmation when action in [:delete]

      def confirm_delete(conn, %{"slug" => slug}) do
        Confirmation.render_page(conn,
          title: "Delete this tournament?",
          consequences: ["Every snapshot, its history and its entry queue are removed."],
          action: ~p"/admin/tournaments/\#{slug}/delete",
          button: "Delete tournament",
          cancel: ~p"/admin/tournaments/\#{slug}"
        )
      end

      def delete(conn, %{"slug" => slug}) do
        Moderation.delete(slug, conn.assigns.admin)
        conn |> put_flash(:info, "Deleted.") |> redirect(to: ~p"/admin/tournaments")
      end

  A page that needs more than sentences - a checkbox for "hide this
  installation's tournaments too", a reason field - renders
  `OpenResultsWeb.Admin.ConfirmationHTML.confirmation/1` itself and puts its
  fields in the slot.

  ## What protects the POST

  1. **The Access token**, on every request, like every admin page.
  2. **The CSRF token**, checked by the `:admin` pipeline before any
     controller runs. The session cookie that holds it is `SameSite=Strict`
     and scoped to `/admin`, so this is the second of two locks against a
     forged cross-site post, not the only one.
  3. **The confirmation marker.** The confirmation form carries a hidden
     `confirm` field naming its own action path, and this plug refuses a
     POST without it with a 400 that changes nothing. So a destructive action
     is only ever carried out from its own confirmation page - not from a
     button some later list page grew, and not from a form aimed at a
     different action.
  """

  @behaviour Plug

  import Plug.Conn

  alias OpenResultsWeb.Admin.ConfirmationHTML

  @field "confirm"

  @impl Plug
  def init(opts), do: opts

  # Asking is always allowed; only a request that acts needs the marker.
  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"], do: conn

  def call(conn, _opts) do
    if confirmed?(conn), do: conn, else: conn |> refuse() |> halt()
  end

  @doc "The name of the hidden field the confirmation form carries."
  def field, do: @field

  @doc """
  Whether this request came from the confirmation page for this very path.
  """
  @spec confirmed?(Plug.Conn.t()) :: boolean()
  def confirmed?(%Plug.Conn{body_params: %{@field => marker}, request_path: path}),
    do: marker == path

  def confirmed?(%Plug.Conn{}), do: false

  @doc """
  Renders a confirmation page.

  Options: `:title`, `:action` (the path the form posts to - by the pattern
  above, the path of this very page), `:button` and `:cancel` are required;
  `:consequences` (a list of sentences), `:hidden` (a map of extra hidden
  fields) and `:danger` (default `true`) are optional.
  """
  @spec render_page(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def render_page(conn, opts) do
    conn
    |> Phoenix.Controller.put_view(html: ConfirmationHTML)
    |> Phoenix.Controller.render(:page,
      page_title: Keyword.fetch!(opts, :title),
      title: Keyword.fetch!(opts, :title),
      action: Keyword.fetch!(opts, :action),
      button: Keyword.fetch!(opts, :button),
      cancel: Keyword.fetch!(opts, :cancel),
      consequences: Keyword.get(opts, :consequences, []),
      hidden: Keyword.get(opts, :hidden, %{}),
      danger: Keyword.get(opts, :danger, true)
    )
  end

  defp refuse(conn) do
    conn
    |> put_status(:bad_request)
    |> Phoenix.Controller.put_view(html: ConfirmationHTML)
    |> Phoenix.Controller.render(:unconfirmed, page_title: "Not confirmed")
  end
end
