defmodule OpenResultsWeb.Admin.InstallationHTML do
  @moduledoc """
  Installation pages of the admin panel. English only, not wrapped in
  gettext - see `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components
  import OpenResultsWeb.Admin.ConfirmationHTML, only: [confirmation: 1]

  # Addresses are nulled this long after their own timestamp - see
  # `OpenResults.Retention` and the contract's "Retention" section.
  @retained_days 30

  def index(assigns) do
    ~H"""
    <h1>Installations</h1>

    <form
      method="get"
      action={~p"/admin/installations"}
      class="admin-filters"
      id="installation-filters"
    >
      <label>
        Status
        <select name="status">
          <option value="">Any</option>
          <option
            :for={status <- ~w(active suspended revoked)}
            value={status}
            selected={@filters["status"] == status}
          >
            {status}
          </option>
        </select>
      </label>
      <label>
        Search
        <input
          type="search"
          name="search"
          value={@filters["search"]}
          placeholder="id, client, version or address"
        />
      </label>
      <button type="submit">Filter</button>
    </form>

    <p :if={@installations == []} class="empty" id="installations-empty">No installation matches.</p>

    <div :if={@installations != []} class="scroller">
      <table class="admin-table" id="installations">
        <caption class="visually-hidden">Installations</caption>
        <thead>
          <tr>
            <th scope="col">Installation</th>
            <th scope="col">Client</th>
            <th scope="col">Status</th>
            <th scope="col">Registered</th>
            <th scope="col">Last seen</th>
            <th class="num" scope="col">Pending and listed</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={installation <- @installations}>
            <td><a href={~p"/admin/installations/#{installation.id}"}>{installation.id}</a></td>
            <td>{client_label(installation)}</td>
            <td><.status value={installation.status} /></td>
            <td>{at(installation.inserted_at)}</td>
            <td>{at(installation.last_seen_at)}</td>
            <td class="num">{installation.tournament_count}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <.pager path={~p"/admin/installations"} params={@filters} page={@page} more?={@more?} />
    """
  end

  def show(assigns) do
    ~H"""
    <p class="admin-crumbs"><a href={~p"/admin/installations"}>Installations</a></p>
    <h1>{@installation.id}</h1>
    <p class="details">
      <span>{client_label(@installation)}</span>
      <span><.status value={@installation.status} /></span>
    </p>

    <nav class="admin-actions-bar" id="installation-actions" aria-label="Actions">
      <a
        :if={@installation.status == "active"}
        href={~p"/admin/installations/#{@installation.id}/suspend"}
      >
        Suspend
      </a>
      <a
        :if={@installation.status == "suspended"}
        href={~p"/admin/installations/#{@installation.id}/unsuspend"}
      >
        Unsuspend
      </a>
      <a
        :if={@installation.status != "revoked"}
        href={~p"/admin/installations/#{@installation.id}/revoke"}
        class="is-danger"
      >
        Revoke
      </a>
      <span :if={@installation.status == "revoked"} class="quiet">Revoked, which is final.</span>
      <a
        :if={@tournaments != []}
        href={~p"/admin/installations/#{@installation.id}/move-tournaments"}
        id="move-tournaments"
      >
        Move all tournaments to another installation…
      </a>
    </nav>

    <dl class="admin-facts" id="installation-facts">
      <dt>Client</dt>
      <dd>{@installation.client || "not given"}</dd>

      <dt>Version</dt>
      <dd>{@installation.client_version || "not given"}</dd>

      <dt>Registered</dt>
      <dd>{at(@installation.inserted_at)}</dd>

      <dt>Registered from</dt>
      <dd id="installation-created-from">
        {address(@installation.created_from, @installation.inserted_at)}
      </dd>

      <dt>Last seen</dt>
      <dd>{at(@installation.last_seen_at)}</dd>

      <dt>Last seen from</dt>
      <dd id="installation-last-seen-from">
        {address(@installation.last_seen_from, @installation.last_seen_at)}
      </dd>

      <dt>Storage</dt>
      <dd id="installation-storage">
        <strong>{bytes(@storage.snapshot_bytes)}</strong>
        <span class="quiet">
          ({thousands(@storage.snapshot_bytes)} bytes) in {@storage.snapshots}
          {if @storage.snapshots == 1, do: "version", else: "versions"} of {@storage.tournaments}
          {if @storage.tournaments == 1, do: "tournament", else: "tournaments"}
        </span>
      </dd>
    </dl>

    <section class="admin-section" id="installation-tournaments">
      <h2>Its tournaments</h2>
      <p :if={@tournaments == []} class="quiet">None.</p>
      <div :if={@tournaments != []} class="scroller">
        <table class="admin-table" id="installation-tournaments-table">
          <caption class="visually-hidden">Its tournaments</caption>
          <thead>
            <tr>
              <th scope="col">Tournament</th>
              <th scope="col">Status</th>
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
              <td>{at(tournament.last_published_at, "not yet")}</td>
              <td class="num">{tournament.open_reports}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="admin-section">
      <h2>What has been done to it</h2>
      <.actions_table actions={@actions} id="installation-actions-table" />
    </section>
    """
  end

  def revoke(assigns) do
    ~H"""
    <.confirmation
      title={"Revoke #{@installation.id} for good?"}
      action={~p"/admin/installations/#{@installation.id}/revoke"}
      button="Revoke installation"
      cancel={~p"/admin/installations/#{@installation.id}"}
      error={@error}
    >
      <p class="admin-consequence">
        {@installation.id} ({client_label(@installation)}) is {@installation.status}.
      </p>
      <p class="admin-consequence">
        Its key is refused on every route except deleting its own tournaments, permanently: a
        revoked installation cannot be unsuspended.
      </p>
      <p class="admin-consequence">
        OpenPairings stops sending and offers the arbiter a deliberate "Register again", which
        gives that machine a new, separate installation. Its tournaments stay with this one.
      </p>

      <fieldset class={["field", "admin-choice", @error && "field-wrong"]} id="revoke-choice">
        <legend>
          Its {@active_tournaments} pending and listed {if @active_tournaments == 1,
            do: "tournament",
            else: "tournaments"}
        </legend>
        <label class="admin-choice-option">
          <input type="radio" name="hide_tournaments" value="true" checked={@choice == "true"} />
          <span>
            <strong>Hide them now.</strong>
            Every public page for them answers "not found" until they are unhidden.
          </span>
        </label>
        <label class="admin-choice-option">
          <input type="radio" name="hide_tournaments" value="false" checked={@choice == "false"} />
          <span>
            <strong>Leave them as they are.</strong>
            They stay up, this installation can no longer update them, and it can still delete them.
          </span>
        </label>
      </fieldset>
    </.confirmation>
    """
  end

  def move(assigns) do
    ~H"""
    <p class="admin-crumbs">
      <a href={~p"/admin/installations/#{@installation.id}"}>{@installation.id}</a>
    </p>
    <h1>Move all of {@installation.id}'s tournaments</h1>

    <p>
      For a laptop that came back as a new installation - after a restore from backup, which
      never carries the installation key. Every tournament below moves to the installation you
      name; the next page shows which laptop that is before anything moves.
    </p>

    <.tournaments_moving tournaments={@tournaments} />

    <form
      method="get"
      action={~p"/admin/installations/#{@installation.id}/move-tournaments"}
      class="admin-form"
      id="move-form"
    >
      <p :if={@error} class="alarm" role="alert" id="move-error">{@error}</p>
      <div class={["field", @error && "field-wrong"]}>
        <label for="move-to">Installation to move them to</label>
        <input
          type="text"
          id="move-to"
          name="to"
          value={@to}
          placeholder="in_..."
          autocomplete="off"
          spellcheck="false"
        />
        <p class="hint">As it appears on that installation's page in this panel.</p>
      </div>
      <div class="actions">
        <button type="submit" id="move-check">Check that installation</button>
        <a href={~p"/admin/installations/#{@installation.id}"} class="cancel">Cancel</a>
      </div>
    </form>
    """
  end

  def move_confirm(assigns) do
    ~H"""
    <.confirmation
      title={"Move #{length(@tournaments)} #{if length(@tournaments) == 1, do: "tournament", else: "tournaments"} from #{@installation.id} to #{@target.id}?"}
      action={~p"/admin/installations/#{@installation.id}/move-tournaments"}
      button={"Move #{length(@tournaments)} #{if length(@tournaments) == 1, do: "tournament", else: "tournaments"}"}
      cancel={~p"/admin/installations/#{@installation.id}"}
      hidden={%{"to" => @target.id}}
    >
      <h2>Moving to</h2>
      <dl class="admin-facts" id="move-target">
        <dt>Installation</dt>
        <dd>{@target.id} <.status value={@target.status} /></dd>

        <dt>Client</dt>
        <dd>{@target.client || "not given"}</dd>

        <dt>Version</dt>
        <dd>{@target.client_version || "not given"}</dd>

        <dt>Registered</dt>
        <dd>{at(@target.inserted_at)}</dd>

        <dt>Last seen</dt>
        <dd>
          {at(@target.last_seen_at)}
          <span :if={@target.last_seen_from} class="quiet">from {@target.last_seen_from}</span>
        </dd>
      </dl>

      <h2>
        {length(@tournaments)} {if length(@tournaments) == 1, do: "tournament", else: "tournaments"} moving
      </h2>
      <.tournaments_moving tournaments={@tournaments} />

      <p class="admin-consequence">
        Each is rebound to {@target.id} and its stored tournament key is cleared, so {@target.id}'s next publish of each, with its own key, claims it. {@installation.id} can no
        longer publish to any of them. Their statuses do not change.
      </p>
      <p class="admin-consequence">
        All of them move or none do, and each move is written to the action log.
      </p>
    </.confirmation>
    """
  end

  attr :tournaments, :list, required: true

  defp tournaments_moving(assigns) do
    ~H"""
    <ul class="admin-moving" id="moving-tournaments">
      <li :for={tournament <- @tournaments}>
        <code>{tournament.slug}</code>
        <span>{tournament.name || "(nothing published yet)"}</span>
        <.status value={tournament.status} />
      </li>
    </ul>
    """
  end

  # A null address is one of three things, and the page says which: never
  # recorded (a client whose address the tunnel did not pass on), forgotten by
  # retention, or - for last-seen - never seen at all.
  defp address(address, _since) when is_binary(address), do: address
  defp address(nil, nil), do: "never seen"

  defp address(nil, %DateTime{} = since) do
    if DateTime.diff(DateTime.utc_now(), since, :second) >= @retained_days * 86_400 do
      "forgotten after #{@retained_days} days"
    else
      "not recorded"
    end
  end
end
