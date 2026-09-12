defmodule OpenResultsWeb.Admin.DashboardController do
  @moduledoc """
  The panel's front page.

  For now it proves the gate: who is signed in, how that was established, and
  which build is answering. The switches, counts and recent actions the
  contract lists (`docs/public-publishing.md`) arrive with
  `OpenResults.Moderation`.
  """
  use OpenResultsWeb, :controller

  def show(conn, _params) do
    render(conn, :show, page_title: "Dashboard")
  end
end
