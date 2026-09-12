defmodule OpenResultsWeb.Admin.ConfirmationProbeController do
  @moduledoc """
  A harmless confirm-then-POST action, routed only in the test environment
  (see `config/test.exs` and the `/admin` scope in the router).

  It exists so the confirmation pattern and the CSRF check can be exercised
  through the real `:admin` pipeline without a fake action ever reaching a
  production route table. "Doing" the action means telling the test process,
  which is the process a `Phoenix.ConnTest` request runs in.
  """
  use OpenResultsWeb, :controller

  alias OpenResultsWeb.Admin.Confirmation

  plug Confirmation when action in [:create]

  def new(conn, _params) do
    Confirmation.render_page(conn,
      title: "Run the probe?",
      consequences: ["Nothing happens except that the test hears about it."],
      action: ~p"/admin/confirmation-probe",
      button: "Run the probe",
      cancel: ~p"/admin",
      hidden: %{"note" => "carried through"}
    )
  end

  def create(conn, params) do
    send(self(), {:confirmation_probe_ran, conn.assigns.admin, params["note"]})

    conn
    |> put_flash(:info, "Probe ran.")
    |> redirect(to: ~p"/admin")
  end
end
