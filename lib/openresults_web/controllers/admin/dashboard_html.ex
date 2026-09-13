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

    <p :if={@storage.disk.status == :low} class="alarm" id="storage-low">
      Free disk space is below the floor: {percent(@storage.disk.free_percent)} free on {@storage.disk.path}, floor {@storage.disk.floor_percent}%. Installation keys are refused
      with storage_low for publishing and new tournaments until there is room again; deleting
      still works and the operator token is unaffected. Free space on that volume (old backups,
      deleted tournaments), or change OPENRESULTS_MIN_FREE_DISK_PERCENT.
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
                <strong>{@counts.tournaments[status]}</strong>
                {if status == :pending, do: "pending: not on player pages yet", else: status}
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

        <dt>Free disk space</dt>
        <dd id="storage-disk">
          <%= if @storage.disk.status == :unknown do %>
            <span>not measured</span>
            <span class="quiet">
              ({@storage.disk.error}). Nothing is refused for storage while it cannot be measured.
            </span>
          <% else %>
            <strong>{percent(@storage.disk.free_percent)}</strong>
            <span class="quiet">
              ({bytes(@storage.disk.available_bytes)} of {bytes(@storage.disk.total_bytes)} on {@storage.disk.path}, measured {at(
                @storage.disk.measured_at
              )})
            </span>
          <% end %>
        </dd>

        <dt>Free-disk floor</dt>
        <dd id="storage-floor">
          <%= if @storage.disk.floor_percent == 0 do %>
            off
          <% else %>
            {@storage.disk.floor_percent}%
            <span class="quiet">
              below it, installation keys may not publish or create tournaments
            </span>
          <% end %>
        </dd>

        <dt>Version cap</dt>
        <dd id="storage-version-cap">
          {@storage.max_versions}
          <span class="quiet">
            versions kept per installation-owned tournament, the oldest pruned on its next
            publish; operator-published tournaments keep every version
          </span>
        </dd>
      </dl>
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

  defp percent(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  defp checked_by(:cloudflare_access),
    do: "Cloudflare Access, and this server's own check of the Access token"

  defp checked_by(:dev_bypass), do: "Nothing - development bypass"
end
