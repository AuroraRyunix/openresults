defmodule OpenResultsWeb.Admin.SettingsHTML do
  @moduledoc """
  The settings page of the admin panel. English only, not wrapped in gettext
  - see `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components
  import OpenResultsWeb.Admin.ConfirmationHTML, only: [confirmation: 1]
  import OpenResultsWeb.Admin.SettingsController, only: [shown: 1]

  alias OpenResults.PublicNotice

  def index(assigns) do
    ~H"""
    <h1>Settings</h1>

    <section class="admin-section" id="server-settings">
      <h2>Server settings</h2>
      <p>
        A value saved here wins over the environment and takes effect on the next request, with
        no restart. Without one, the environment's value is in force, and without that the
        built-in default. Every change is written to the action log.
      </p>
      <div class="scroller">
        <table class="admin-table" id="server-settings-table">
          <caption class="visually-hidden">Server settings</caption>
          <thead>
            <tr>
              <th scope="col">Setting</th>
              <th scope="col">In force</th>
              <th scope="col">From</th>
              <th scope="col">Environment</th>
              <th scope="col">Default</th>
              <th scope="col"><span class="visually-hidden">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={setting <- @settings} id={"setting-#{setting.key}"}>
              <th scope="row">
                {OpenResults.ServerSettings.spec(setting.key).label}
                <span class="quiet admin-details"><code>{setting.variable}</code></span>
              </th>
              <td><strong>{shown(setting.value)}</strong></td>
              <td><.source value={setting.source} /></td>
              <td>
                {if setting.environment == nil, do: "not set", else: shown(setting.environment)}
              </td>
              <td>{shown(setting.default)}</td>
              <td>
                <a href={~p"/admin/settings/#{setting.key}"}>Change</a>
                <a :if={setting.source == :panel} href={~p"/admin/settings/#{setting.key}/reset"}>
                  Reset to default
                </a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="admin-section" id="notice-settings">
      <h2>Public notice</h2>
      <p>
        A short message on every public page, above the content, in the visitor's language -
        not on the projector view, and not here.
      </p>
      <%= if @notice do %>
        <p id="notice-state">
          <%= cond do %>
            <% not PublicNotice.active?(@notice, @now) -> %>
              <strong>Expired</strong>
              at {at(@notice.expires_at)}: no longer shown. Clear it, or set a new one.
            <% @notice.expires_at -> %>
              <strong>Showing</strong> until {at(@notice.expires_at)}.
            <% true -> %>
              <strong>Showing</strong> until it is cleared.
          <% end %>
          <span class="quiet">Set by {@notice.set_by} on {at(@notice.set_at)}.</span>
        </p>
        <.notice_previews notice={@notice} />
        <nav class="admin-actions-bar" aria-label="Notice actions">
          <a href={~p"/admin/settings/notice"} id="change-notice">Change the notice</a>
          <a href={~p"/admin/settings/notice/clear"} id="clear-notice">Clear the notice</a>
        </nav>
      <% else %>
        <p class="quiet" id="notice-state">No notice is set.</p>
        <nav class="admin-actions-bar" aria-label="Notice actions">
          <a href={~p"/admin/settings/notice"} id="set-notice">Set a notice</a>
        </nav>
      <% end %>
    </section>

    <section class="admin-section" id="bel-roster">
      <h2>Belgian (KBSB/FRBE) roster relay</h2>
      <p>
        Read-only: see docs/federations-bel.md. Configured with <code>OPENRESULTS_KBSB_API_URL</code>
        / <code>OPENRESULTS_KBSB_API_KEY</code>, below.
      </p>
      <%= if @bel.configured? do %>
        <dl class="admin-facts" id="bel-roster-facts">
          <dt>Last successful sync</dt>
          <dd>{at(@bel.updated_at)}</dd>
          <dt>Players</dt>
          <dd>{thousands(@bel.count)}</dd>
          <dt>Last error</dt>
          <dd>
            <%= if @bel.last_error do %>
              {@bel.last_error} <span class="quiet">({at(@bel.last_error_at)})</span>
            <% else %>
              none
            <% end %>
          </dd>
        </dl>
      <% else %>
        <p class="quiet" id="bel-roster-state">Not configured on this server.</p>
      <% end %>
    </section>

    <section class="admin-section" id="locked-settings">
      <h2>Set only in the environment</h2>
      <p>
        These are never changed from the panel: they are security boundaries, or a mistake with
        them here could lock you out of the panel itself. Change them in the deploy's
        environment and restart. Secret values are never shown.
      </p>
      <div class="scroller">
        <table class="admin-table" id="locked-settings-table">
          <caption class="visually-hidden">Set only in the environment</caption>
          <thead>
            <tr>
              <th scope="col">Variable</th>
              <th scope="col">State</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @locked}>
              <th scope="row"><code>{item.variable}</code></th>
              <td>
                {item.value || if(item.set?, do: "set", else: "not set")}
                <span :if={item.secret?} class="quiet">(secret)</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :value, :atom, required: true

  defp source(assigns) do
    ~H"""
    <span class={["admin-status", @value == :panel && "admin-status-open"]}>
      {case @value do
        :panel -> "panel"
        :environment -> "environment"
        :default -> "default"
      end}
    </span>
    """
  end

  def setting(assigns) do
    ~H"""
    <p class="admin-crumbs"><a href={~p"/admin/settings"}>Settings</a></p>
    <h1>{@spec.label}</h1>

    <dl class="admin-facts" id="setting-facts">
      <dt>In force</dt>
      <dd>
        {shown(@setting.value)} <span class="quiet">({source_label(@setting)})</span>
      </dd>
      <dt>Environment</dt>
      <dd>
        <code>{@spec.variable}</code>
        {if @setting.environment == nil, do: "not set", else: shown(@setting.environment)}
      </dd>
      <dt>Default</dt>
      <dd>{shown(@setting.default)}</dd>
    </dl>

    <form
      method="get"
      action={~p"/admin/settings/#{@setting.key}"}
      class="admin-form"
      id="setting-form"
    >
      <p :if={@error} class="alarm" role="alert" id="setting-error">
        {@error} Nothing was changed.
      </p>
      <div class={["field", @error && "field-wrong"]}>
        <label for="setting-value">New value</label>
        <input
          type={
            case @spec.type do
              :integer -> "number"
              :email -> "email"
              _text -> "text"
            end
          }
          id="setting-value"
          name="value"
          value={@value || default_input(@setting)}
          min={@spec[:min]}
          max={@spec[:max]}
          autocomplete="off"
          spellcheck="false"
          aria-describedby="setting-hint"
        />
        <p class="hint" id="setting-hint">{hint(@spec)}</p>
      </div>
      <div class="actions">
        <button type="submit" id="setting-check">Check</button>
        <a href={~p"/admin/settings"} class="cancel">Cancel</a>
      </div>
    </form>
    """
  end

  def notice_form(assigns) do
    ~H"""
    <p class="admin-crumbs"><a href={~p"/admin/settings"}>Settings</a></p>
    <h1>Set the public notice</h1>

    <form method="get" action={~p"/admin/settings/notice"} class="admin-form" id="notice-form">
      <p :if={@errors != %{}} class="alarm" role="alert" id="notice-form-errors">
        Nothing was changed. Fix what is marked below.
      </p>

      <div :for={{lang, label} <- languages()} class={["field", @errors[lang] && "field-wrong"]}>
        <label for={"notice-#{lang}"}>{label}</label>
        <textarea
          id={"notice-#{lang}"}
          name={"notice[#{lang}]"}
          rows="2"
          maxlength={PublicNotice.max_length()}
          lang={Atom.to_string(lang)}
        >{@values[Atom.to_string(lang)]}</textarea>
        <p :if={@errors[lang]} class="wrong" id={"notice-#{lang}-error"}>{@errors[lang]}</p>
      </div>
      <p class="hint">
        Plain text, one line, at most {PublicNotice.max_length()} characters each. A page in Dutch
        or French with no text of its own shows the English.
      </p>

      <fieldset class={["field", @errors[:level] && "field-wrong"]}>
        <legend>Level</legend>
        <label class="admin-choice-option">
          <input
            type="radio"
            name="notice[level]"
            value="info"
            checked={@values["level"] != "warning"}
          />
          <span><strong>Information</strong> - a quiet panel.</span>
        </label>
        <label class="admin-choice-option">
          <input
            type="radio"
            name="notice[level]"
            value="warning"
            checked={@values["level"] == "warning"}
          />
          <span><strong>Warning</strong> - filled in the theme's accent colour.</span>
        </label>
        <p :if={@errors[:level]} class="wrong" id="notice-level-error">{@errors[:level]}</p>
      </fieldset>

      <div class={["field", @errors[:expires_at] && "field-wrong"]}>
        <label for="notice-expires">Stop showing it at (UTC, optional)</label>
        <input
          type="datetime-local"
          id="notice-expires"
          name="notice[expires_at]"
          value={local_input(@values["expires_at"])}
        />
        <p :if={@errors[:expires_at]} class="wrong" id="notice-expires-error">
          {@errors[:expires_at]}
        </p>
        <p class="hint">Empty: it shows until it is cleared.</p>
      </div>

      <div class="actions">
        <button type="submit" id="notice-check">Preview</button>
        <a href={~p"/admin/settings"} class="cancel">Cancel</a>
      </div>
    </form>
    """
  end

  def notice_confirm(assigns) do
    ~H"""
    <.confirmation
      title={if @current, do: "Replace the public notice?", else: "Set the public notice?"}
      action={~p"/admin/settings/notice"}
      button="Set notice"
      cancel={~p"/admin/settings"}
      hidden={@hidden}
      danger={false}
    >
      <p class="admin-consequence">
        It shows on every public page at once, above the content, until {if @notice.expires_at,
          do: at(@notice.expires_at),
          else: "it is cleared"}. <span :if={@current}>It replaces the notice showing now.</span>
      </p>
      <h2>Preview</h2>
      <.notice_previews notice={@notice} />
    </.confirmation>
    """
  end

  attr :notice, :map, required: true

  defp notice_previews(assigns) do
    ~H"""
    <div class="admin-notice-previews" id="notice-previews">
      <div :for={{lang, label} <- languages()} class="admin-notice-preview">
        <p class="admin-count-title">{label}</p>
        <OpenResultsWeb.Layouts.public_notice
          id={"notice-preview-#{lang}"}
          notice={PublicNotice.for_locale(notice_for_preview(@notice), Atom.to_string(lang))}
        />
      </div>
    </div>
    """
  end

  defp notice_for_preview(notice), do: Map.put_new(notice, :set_at, DateTime.utc_now())

  defp languages, do: [en: "English (required)", nl: "Dutch", fr: "French"]

  defp source_label(%{source: :panel}), do: "saved in the panel"
  defp source_label(%{source: :environment, variable: v}), do: "from #{v}"
  defp source_label(%{source: :default}), do: "the built-in default"

  defp default_input(%{value: value}) when is_integer(value), do: Integer.to_string(value)
  defp default_input(%{value: value}) when is_binary(value), do: value
  defp default_input(_), do: nil

  defp hint(%{type: :integer, min: min, max: nil, help: help}),
    do: "A whole number of at least #{min}. #{help}"

  defp hint(%{type: :integer, min: min, max: max, help: help}),
    do: "A whole number from #{min} to #{max}. #{help}"

  defp hint(%{type: :https_url, help: help}), do: "A full https:// address. #{help}"
  defp hint(%{type: :text, max: max, help: help}), do: "At most #{max} characters. #{help}"
  defp hint(%{type: :email, help: help}), do: "One email address. #{help}"

  # `2026-09-13T22:30:00Z` back into what a datetime-local input shows.
  defp local_input(nil), do: nil

  defp local_input(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> Calendar.strftime(at, "%Y-%m-%dT%H:%M")
      _ -> nil
    end
  end
end
