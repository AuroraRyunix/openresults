defmodule OpenResultsWeb.Admin.DashboardHTML do
  @moduledoc """
  The dashboard's markup. English only, not wrapped in gettext - see
  `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components

  def show(assigns) do
    ~H"""
    <h1>Dashboard</h1>

    <p :if={not @public_publishing?} class="alarm" id="public-publishing-off">
      Public publishing is switched off on this server: OPENRESULTS_PUBLIC_PUBLISHING is not set
      to enabled. The switches below are stored, but change nothing until it is.
    </p>

    <section class="admin-section" id="switches">
      <h2>Switches</h2>
      <div class="admin-switches">
        <div class="admin-switch" id="switch-registration_open">
          <p class="admin-switch-name">Registration</p>
          <p class="admin-switch-state">
            {if @settings.registration_open, do: "Open", else: "Closed"}
          </p>
          <p class="quiet">
            Whether OpenPairings desktop copies that ask can get an installation key.
          </p>
          <a href={~p"/admin/switches/registration_open"}>
            {if @settings.registration_open, do: "Close registration", else: "Open registration"}
          </a>
        </div>

        <div class="admin-switch" id="switch-public_publishing_paused">
          <p class="admin-switch-name">Public publishing</p>
          <p class={[
            "admin-switch-state",
            @settings.public_publishing_paused && "is-paused"
          ]}>
            {if @settings.public_publishing_paused, do: "Paused", else: "Active"}
          </p>
          <p class="quiet">
            Whether installation keys may publish and create tournaments. Pausing takes
            arbiters' live updates offline.
          </p>
          <a href={~p"/admin/switches/public_publishing_paused"}>
            {if @settings.public_publishing_paused,
              do: "Resume publishing",
              else: "Pause publishing"}
          </a>
        </div>
      </div>
    </section>

    <section class="admin-section" id="counts">
      <h2>At a glance</h2>
      <div class="admin-counts">
        <div class="admin-count-group">
          <p class="admin-count-title">Tournaments</p>
          <ul>
            <li :for={status <- ~w(pending listed hidden)a}>
              <a href={~p"/admin/tournaments?#{[status: status]}"}>
                <strong>{@counts.tournaments[status]}</strong> {status}
              </a>
            </li>
          </ul>
        </div>

        <div class="admin-count-group">
          <p class="admin-count-title">Installations</p>
          <ul>
            <li :for={status <- ~w(active suspended revoked)a}>
              <a href={~p"/admin/installations?#{[status: status]}"}>
                <strong>{@counts.installations[status]}</strong> {status}
              </a>
            </li>
          </ul>
        </div>

        <div class="admin-count-group">
          <p class="admin-count-title">Needing attention</p>
          <ul>
            <li>
              <a href={~p"/admin/reports"}>
                <strong id="count-open-reports">{@counts.open_reports}</strong>
                {if @counts.open_reports == 1, do: "open report", else: "open reports"}
              </a>
            </li>
            <li>
              <a href={~p"/admin/address-blocks"}>
                <strong>{@counts.address_blocks}</strong>
                {if @counts.address_blocks == 1, do: "address block", else: "address blocks"}
              </a>
            </li>
          </ul>
        </div>
      </div>
    </section>

    <section class="admin-section" id="storage">
      <h2>Storage</h2>
      <dl class="admin-facts">
        <dt>Published snapshots</dt>
        <dd>
          <strong id="storage-snapshot-bytes">{bytes(@storage.snapshot_bytes)}</strong>
          <span class="quiet">
            ({thousands(@storage.snapshot_bytes)} bytes) in {thousands(@storage.snapshots)}
            {if @storage.snapshots == 1, do: "version", else: "versions"} of {thousands(
              @storage.tournaments
            )} {if @storage.tournaments == 1, do: "tournament", else: "tournaments"}
          </span>
        </dd>

        <dt>Database file</dt>
        <dd>
          {bytes(@storage.database_bytes)}
          <span :if={@storage.database_bytes} class="quiet">
            ({thousands(@storage.database_bytes)} bytes)
          </span>
        </dd>
      </dl>
      <p class="quiet">
        Every changed version of a tournament is kept, so published snapshots grow with every
        publish until a tournament is deleted. Nothing bounds that yet.
      </p>
    </section>

    <section class="admin-section" id="recent-actions">
      <h2>Recent actions</h2>
      <.actions_table actions={@actions} id="recent-actions-table" />
      <p><a href={~p"/admin/action-log"}>The whole action log</a></p>
    </section>

    <section class="admin-section">
      <h2>This session</h2>
      <dl class="admin-facts" id="admin-facts">
        <dt>Administrator</dt>
        <dd>{@admin.email}</dd>

        <dt>Checked by</dt>
        <dd>{checked_by(@admin_via)}</dd>

        <dt>Build</dt>
        <dd>{OpenResults.Build.long()}</dd>
      </dl>
    </section>
    """
  end

  defp checked_by(:cloudflare_access),
    do: "Cloudflare Access, and this server's own check of the Access token"

  defp checked_by(:dev_bypass), do: "Nothing - development bypass"
end
