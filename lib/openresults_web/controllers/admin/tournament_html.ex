defmodule OpenResultsWeb.Admin.TournamentHTML do
  @moduledoc """
  Tournament pages of the admin panel. English only, not wrapped in gettext -
  see `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components
  import OpenResultsWeb.Admin.ConfirmationHTML, only: [confirmation: 1]

  alias OpenResultsWeb.Admin.TournamentController

  def index(assigns) do
    ~H"""
    <h1>Tournaments</h1>

    <form method="get" action={~p"/admin/tournaments"} class="admin-filters" id="tournament-filters">
      <label>
        Status
        <select name="status">
          <option value="">Any</option>
          <option
            :for={status <- ~w(pending listed hidden)}
            value={status}
            selected={@filters["status"] == status}
          >
            {status}
          </option>
        </select>
      </label>
      <label class="admin-check">
        <input type="checkbox" name="reported" value="true" checked={@filters["reported"] == "true"} />
        With open reports
      </label>
      <label>
        Search
        <input type="search" name="search" value={@filters["search"]} placeholder="slug or name" />
      </label>
      <button type="submit">Filter</button>
    </form>

    <p :if={@tournaments == []} class="empty" id="tournaments-empty">No tournament matches.</p>

    <div :if={@tournaments != []} class="scroller">
      <table class="admin-table" id="tournaments">
        <caption class="visually-hidden">Tournaments</caption>
        <thead>
          <tr>
            <th scope="col">Tournament</th>
            <th scope="col">Status</th>
            <th scope="col">Owner</th>
            <th scope="col">Last publish</th>
            <th class="num" scope="col">Open reports</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={tournament <- @tournaments}>
            <td>
              <a href={~p"/admin/tournaments/#{tournament.slug}"}>
                {tournament.name || "(nothing published yet)"}
              </a>
              <span class="quiet">{tournament.slug}</span>
            </td>
            <td><.status value={tournament.status} /></td>
            <td><.owner installation_id={tournament.installation_id} /></td>
            <td>{at(tournament.last_published_at, "not yet")}</td>
            <td class="num">{tournament.open_reports}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <.pager path={~p"/admin/tournaments"} params={@filters} page={@page} more?={@more?} />
    """
  end

  def show(assigns) do
    ~H"""
    <p class="admin-crumbs"><a href={~p"/admin/tournaments"}>Tournaments</a></p>
    <h1>{@tournament.name || "(nothing published yet)"}</h1>
    <p class="details">
      <span>{@tournament.slug}</span>
      <span><.status value={@tournament.status} /></span>
    </p>

    <nav class="admin-actions-bar" id="tournament-actions" aria-label="Actions">
      <a
        :if={@tournament.status == "pending"}
        href={~p"/admin/tournaments/#{@tournament.slug}/approve"}
      >
        Approve
      </a>
      <a
        :if={@tournament.status in ["pending", "listed"]}
        href={~p"/admin/tournaments/#{@tournament.slug}/hide"}
      >
        Hide
      </a>
      <a :if={@tournament.status == "hidden"} href={~p"/admin/tournaments/#{@tournament.slug}/unhide"}>
        Unhide
      </a>
      <a href={~p"/admin/tournaments/#{@tournament.slug}/transfer"}>Transfer</a>
      <a href={~p"/admin/tournaments/#{@tournament.slug}/delete"} class="is-danger">Delete</a>
    </nav>

    <dl class="admin-facts" id="tournament-facts">
      <dt>Public page</dt>
      <dd>
        <%= cond do %>
          <% @tournament.status == "hidden" -> %>
            <span class="quiet">hidden: it answers "not found" to the public</span>
          <% is_nil(@stats.last_published_at) -> %>
            <span class="quiet">nothing published yet</span>
          <% true -> %>
            <a href={~p"/t/#{@tournament.slug}"}>/t/{@tournament.slug}</a>
        <% end %>
      </dd>

      <dt>Owner</dt>
      <dd>
        <%= if @tournament.installation do %>
          <a href={~p"/admin/installations/#{@tournament.installation.id}"}>
            {@tournament.installation.id}
          </a>
          <span class="quiet">
            {client_label(@tournament.installation)},
            <.status value={@tournament.installation.status} />
          </span>
        <% else %>
          <span class="quiet">nobody: published with the operator token</span>
        <% end %>
      </dd>

      <dt :if={@tournament.minted_at}>Minted</dt>
      <dd :if={@tournament.minted_at}>{at(@tournament.minted_at)}</dd>

      <dt>First publish</dt>
      <dd>{at(@stats.first_published_at, "not yet")}</dd>

      <dt>Last publish</dt>
      <dd>{at(@stats.last_published_at, "not yet")}</dd>

      <dt>Current snapshot</dt>
      <dd id="tournament-current-bytes">
        {bytes(@stats.current_bytes)}
        <span :if={@stats.current_bytes} class="quiet">({thousands(@stats.current_bytes)} bytes)</span>
      </dd>

      <dt>Stored versions</dt>
      <dd>{@stats.snapshots}, {bytes(@stats.snapshot_bytes)} in all</dd>

      <dt>Entries waiting</dt>
      <dd>{@stats.registrations}</dd>
    </dl>

    <section class="admin-section" id="tournament-reports">
      <h2>Reports about it</h2>
      <.reports_table reports={@reports} show_tournament={false} id="tournament-reports-table" />
    </section>

    <section class="admin-section">
      <h2>What has been done to it</h2>
      <.actions_table actions={@actions} id="tournament-actions-table" />
    </section>
    """
  end

  def transfer(assigns) do
    ~H"""
    <.confirmation
      title={"Transfer #{TournamentController.label(@tournament)} to another installation?"}
      action={~p"/admin/tournaments/#{@tournament.slug}/transfer"}
      button="Transfer tournament"
      cancel={~p"/admin/tournaments/#{@tournament.slug}"}
      error={@error}
    >
      <p class="admin-consequence">
        <%= if @tournament.installation_id do %>
          Owned now by {@tournament.installation_id}.
        <% else %>
          Owned now by nobody: it was published with the operator token.
        <% end %>
      </p>
      <p class="admin-consequence">
        It is rebound to the installation you name, and its stored tournament key is cleared,
        so that installation's next publish with its own key claims it.
      </p>
      <p class="admin-consequence">
        The current owner can no longer publish to it. Its status, {@tournament.status}, does not
        change. A revoked installation cannot receive it.
      </p>

      <div class="field">
        <label for="transfer-installation-id">Installation id</label>
        <input
          type="text"
          id="transfer-installation-id"
          name="installation_id"
          value={@installation_id}
          placeholder="in_..."
          autocomplete="off"
          spellcheck="false"
        />
        <p class="hint">As it appears on the installation's page in this panel.</p>
      </div>
    </.confirmation>
    """
  end

  attr :installation_id, :string, default: nil

  defp owner(assigns) do
    ~H"""
    <a :if={@installation_id} href={~p"/admin/installations/#{@installation_id}"}>
      {@installation_id}
    </a>
    <span :if={is_nil(@installation_id)} class="quiet">operator</span>
    """
  end
end
