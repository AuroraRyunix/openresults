defmodule OpenResultsWeb.Admin.AddressBlockHTML do
  @moduledoc """
  Address block pages of the admin panel. English only, not wrapped in
  gettext - see `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components
  import OpenResultsWeb.Admin.ConfirmationHTML, only: [confirmation: 1]

  def index(assigns) do
    ~H"""
    <h1>Address blocks</h1>

    <p>
      A blocked address or range cannot register an installation, create a tournament or publish
      with an installation key. Reading pages, the entry and report forms, deleting a tournament
      and the operator token are never blocked.
    </p>

    <nav class="admin-actions-bar" aria-label="Actions">
      <a href={~p"/admin/address-blocks/new"} id="add-block">Block an address</a>
    </nav>

    <p :if={@blocks == []} class="empty" id="blocks-empty">No address is blocked.</p>

    <div :if={@blocks != []} class="scroller">
      <table class="admin-table" id="blocks">
        <thead>
          <tr>
            <th>Address or range</th>
            <th>Until</th>
            <th>Reason</th>
            <th>Blocked by</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={block <- @blocks}>
            <td><code>{block.cidr}</code></td>
            <td>{at(block.expires_at)}</td>
            <td class="admin-excerpt">{block.reason}</td>
            <td>{block.created_by} <span class="quiet">{at(block.inserted_at)}</span></td>
            <td><a href={~p"/admin/address-blocks/#{block.id}/unblock"}>Lift</a></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def new(assigns) do
    ~H"""
    <p class="admin-crumbs"><a href={~p"/admin/address-blocks"}>Address blocks</a></p>
    <h1>Block an address</h1>

    <.form
      for={%{}}
      action={~p"/admin/address-blocks/new"}
      method="post"
      id="block-form"
      class="admin-form"
    >
      <p :if={@errors != %{}} class="alarm" role="alert" id="block-form-errors">
        Nothing has been blocked. Fix what is marked below.
      </p>

      <div class={["field", @errors[:cidr] && "field-wrong"]}>
        <label for="block-address">IP address or CIDR range</label>
        <input
          type="text"
          id="block-address"
          name="block[address]"
          value={@values["address"]}
          autocomplete="off"
          spellcheck="false"
        />
        <p :if={@errors[:cidr]} class="wrong" id="block-address-error">{@errors[:cidr]}</p>
        <p class="hint">One address, like 203.0.113.7, or a range, like 203.0.113.0/24. IPv6 too.</p>
      </div>

      <fieldset class={["field", @errors[:expires_at] && "field-wrong"]}>
        <legend>Lasts for</legend>
        <div class="admin-inline">
          <input
            type="number"
            id="block-duration"
            name="block[duration]"
            value={@values["duration"]}
            min="1"
            aria-label="How long"
          />
          <select id="block-unit" name="block[unit]" aria-label="Unit">
            <option value="hours" selected={@values["unit"] == "hours"}>hours</option>
            <option value="days" selected={@values["unit"] != "hours"}>days</option>
          </select>
        </div>
        <p :if={@errors[:expires_at]} class="wrong" id="block-expiry-error">{@errors[:expires_at]}</p>
        <p class="hint">Every block expires, after at most 30 days.</p>
      </fieldset>

      <div class={["field", @errors[:reason] && "field-wrong"]}>
        <label for="block-reason">Reason</label>
        <textarea id="block-reason" name="block[reason]" rows="3" maxlength="2000">{@values["reason"]}</textarea>
        <p :if={@errors[:reason]} class="wrong" id="block-reason-error">{@errors[:reason]}</p>
        <p class="hint">Kept with the block and in the action log.</p>
      </div>

      <div class="actions">
        <button type="submit" id="block-check">Check who this reaches</button>
        <a href={~p"/admin/address-blocks"} class="cancel">Cancel</a>
      </div>
    </.form>
    """
  end

  def confirm(assigns) do
    ~H"""
    <.confirmation
      title={"Block #{@cidr}?"}
      action={~p"/admin/address-blocks"}
      button="Block"
      cancel={~p"/admin/address-blocks"}
      hidden={
        %{
          "block[address]" => @cidr,
          "block[expires_at]" => DateTime.to_iso8601(@expires_at),
          "block[reason]" => @reason
        }
      }
    >
      <p class="admin-reach" id="block-reach">
        <%= case @seen do %>
          <% 0 -> %>
            <strong>No installation</strong>
            was seen from this {range_word(@cidr)} in the last 30 days.
          <% 1 -> %>
            <strong>1 installation</strong>
            was seen from this {range_word(@cidr)} in the last 30 days.
          <% n -> %>
            <strong>{n} installations</strong>
            were seen from this {range_word(@cidr)} in the last 30 days.
        <% end %>
      </p>
      <p class="admin-consequence">
        A block reaches everyone behind that address, not one person: a club's wifi or a mobile
        carrier can put many people on one address, and every one of them is refused.
      </p>
      <p class="admin-consequence">
        Until {at(@expires_at)}, registering an installation, creating a tournament and publishing
        with an installation key are refused from here, and arbiters are told to contact the
        operator. Reading pages, the entry and report forms, deleting a tournament and the
        operator token are not affected.
      </p>
      <p class="admin-consequence">Reason: {@reason}</p>
    </.confirmation>
    """
  end

  defp range_word(cidr) do
    if String.ends_with?(cidr, "/32") or String.ends_with?(cidr, "/128"),
      do: "address",
      else: "range"
  end
end
