defmodule OpenResultsWeb.Admin.RelayKeyHTML do
  @moduledoc """
  Relay key pages of the admin panel. English only, not wrapped in gettext -
  see `OpenResultsWeb.Admin.Layouts`.

  The key is rendered by `created/1` and nowhere else; every other page here
  has no way to know it, because the server does not.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components
  import OpenResultsWeb.Admin.ConfirmationHTML, only: [confirmation: 1]

  alias OpenResultsWeb.Admin.TournamentController

  def index(assigns) do
    ~H"""
    <p class="admin-crumbs">
      <a href={~p"/admin/tournaments"}>Tournaments</a>
      /
      <a href={~p"/admin/tournaments/#{@tournament.slug}"}>{TournamentController.label(@tournament)}</a>
    </p>

    <h1>Relay keys</h1>

    <p>
      A relay key lets one box in the hall report the boards of <strong>{@tournament.slug}</strong>
      and do nothing else: no other tournament, no publishing, no admin.
      Put one on the relay instead of the tournament's own key or an installation key.
    </p>

    <nav class="admin-actions-bar" id="relay-keys-actions" aria-label="Actions">
      <a :if={@active < @max_active} href={~p"/admin/tournaments/#{@tournament.slug}/relay-keys/new"}>
        Make a relay key
      </a>
    </nav>

    <p :if={@keys == []} class="empty" id="relay-keys-empty">No relay key has been made.</p>

    <div :if={@keys != []} class="scroller">
      <table class="admin-table" id="relay-keys">
        <caption class="visually-hidden">Relay keys</caption>
        <thead>
          <tr>
            <th scope="col">Label</th>
            <th scope="col">Ends</th>
            <th scope="col">Made</th>
            <th scope="col">Last used</th>
            <th scope="col">State</th>
            <th scope="col"><span class="visually-hidden">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={key <- @keys} id={"relay-key-#{key.id}"}>
            <td>{key.label || "(no label)"}</td>
            <td><code>{key.hint}</code></td>
            <td>{at(key.inserted_at)} <span class="quiet">by {key.created_by}</span></td>
            <td>{at(key.last_used_at, "never")}</td>
            <td>
              <%= if key.revoked_at do %>
                revoked {at(key.revoked_at)} <span class="quiet">by {key.revoked_by}</span>
              <% else %>
                in use
              <% end %>
            </td>
            <td>
              <a
                :if={is_nil(key.revoked_at)}
                href={~p"/admin/tournaments/#{@tournament.slug}/relay-keys/#{key.id}/revoke"}
                class="is-danger"
              >
                Revoke
              </a>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def new(assigns) do
    ~H"""
    <.confirmation
      title={"Make a relay key for #{TournamentController.label(@tournament)}?"}
      action={~p"/admin/tournaments/#{@tournament.slug}/relay-keys/new"}
      button="Make the key"
      cancel={~p"/admin/tournaments/#{@tournament.slug}/relay-keys"}
      danger={false}
      error={@error}
    >
      <p class="admin-consequence">
        The key is shown once, on the next page, and cannot be shown again: this server keeps
        only a fingerprint of it.
      </p>

      <p class="admin-consequence">
        It lets the holder post moves, clocks and results for {@tournament.slug} to the live
        boards, and nothing else.
      </p>

      <div class="field">
        <label for="relay-key-label">Label</label>
        <input
          type="text"
          id="relay-key-label"
          name="label"
          value={@label}
          maxlength="80"
          autocomplete="off"
        />
        <p class="hint">Optional. What is written on the box, so you can tell the keys apart.</p>
      </div>
    </.confirmation>
    """
  end

  def created(assigns) do
    ~H"""
    <p class="admin-crumbs">
      <a href={~p"/admin/tournaments/#{@tournament.slug}/relay-keys"}>Relay keys</a>
    </p>

    <h1>Relay key made</h1>

    <p class="alarm" role="alert" id="relay-key-once">
      Copy it now. This is the only time it is shown; nothing on this server can show it again.
    </p>

    <p>
      <code id="relay-key-secret" class="relay-key-secret">{@key}</code>
    </p>

    <p>
      Send it to the live endpoint as <code>Authorization: Bearer &lt;key&gt;</code>
      for <strong>{@tournament.slug}</strong>. It needs no tournament key.
    </p>

    <p><a href={~p"/admin/tournaments/#{@tournament.slug}/relay-keys"}>Back to the relay keys</a></p>
    """
  end
end
