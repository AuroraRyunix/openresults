defmodule OpenResultsWeb.Admin.DashboardHTML do
  @moduledoc """
  The dashboard's markup. English only, not wrapped in gettext - see
  `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  def show(assigns) do
    ~H"""
    <h1>Dashboard</h1>

    <dl class="admin-facts" id="admin-facts">
      <dt>Administrator</dt>
      <dd>{@admin.email}</dd>

      <dt>Checked by</dt>
      <dd>{checked_by(@admin_via)}</dd>

      <dt>Build</dt>
      <dd>{OpenResults.Build.long()}</dd>
    </dl>
    """
  end

  defp checked_by(:cloudflare_access),
    do: "Cloudflare Access, and this server's own check of the Access token"

  defp checked_by(:dev_bypass), do: "Nothing - development bypass"
end
