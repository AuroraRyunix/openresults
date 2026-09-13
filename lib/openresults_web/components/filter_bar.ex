defmodule OpenResultsWeb.Components.FilterBar do
  @moduledoc """
  The one filter/sort bar shared by the standings, round pairings and
  cross-table pages - see `OpenResultsWeb.Tournament.Filter` for what it
  actually filters and sorts, and `OpenResultsWeb.FilterParams` for the
  query string it reads and writes.

  ## Why a plain `<form method="get">` and nothing cleverer

  Every control here is a real `<select>` or `<input>`, inside one form,
  submitted by a visible button. That is not a fallback for JavaScript
  being off - it is the only mechanism this bar has. A GET form is
  shareable and bookmarkable by construction (the browser puts the values
  in the address bar for free), works from a cold load with no script
  having run yet, and needs nothing from this app beyond rendering the
  controls with the request's own values already selected - which is what
  makes a plain `Phoenix.ConnTest` GET with query params a complete test of
  it, no browser required.

  The small inline `<script>` at the bottom of `filter_bar/1` is the ONLY
  optional enhancement on top of this - the same pattern
  `index.html.heex`'s own search box already uses on this site, inline
  rather than a bundled asset because the public pages carry no
  `script-src` restriction that would refuse it
  (unlike the admin panel - see `OpenResultsWeb.Plugs.AdminHeaders`, which
  is `script-src 'none'` on purpose and nowhere near this bar). It submits
  the form on a control's `change` event and debounces the search box, so a
  reader with JavaScript rarely has to find the button - but it always does
  a real navigation (`form.requestSubmit()`), never a fetch-and-patch, and
  it re-registers itself on `openresults:updated` exactly like the other
  two, so it keeps working across the 20-second refresher's swap - see the
  root layout's own comment on that event.
  """

  use Phoenix.Component
  use Gettext, backend: OpenResultsWeb.Gettext

  alias OpenResultsWeb.FilterParams

  @doc """
  Renders the bar.

  `action` is the page's own path (the controller renders this same page
  for a GET with query params, so the form submits back to exactly where
  it is). `categories`/`federations`/`clubs` are the option lists this
  TOURNAMENT actually offers - `[]` omits that one control entirely, per
  `Tournament.Filter.categories/1` and `player_values/2`. `sort?` is false
  on the round and cross-table pages, which filter their rows but do not
  reorder them - see `Tournament.Filter`'s own moduledoc on `round_boards/3`
  and `crosstable_rows/3` for why.
  """
  attr :action, :string, required: true
  attr :filters, FilterParams, required: true
  attr :categories, :list, default: []
  attr :federations, :list, default: []
  attr :clubs, :list, default: []
  attr :teams, :list, default: []
  attr :sort?, :boolean, default: true
  attr :empty?, :boolean, default: false

  def filter_bar(assigns) do
    assigns =
      assigns
      |> assign(
        :any_control?,
        assigns.categories != [] or assigns.federations != [] or assigns.clubs != [] or
          assigns.teams != []
      )

    ~H"""
    <div :if={@any_control? or @sort?} class="filter-bar">
      <form method="get" action={@action} class="filter-form" data-filter-form>
        <fieldset class="field filter-fields">
          <legend class="visually-hidden">{gettext("Filter and sort")}</legend>

          <label :if={@categories != []} class="filter-field">
            <span>{gettext("Category")}</span>
            <select name="category">
              <option value="">{gettext("All categories")}</option>
              <option
                :for={category <- @categories}
                value={category}
                selected={@filters.category == category}
              >
                {category}
              </option>
            </select>
          </label>

          <label :if={@federations != []} class="filter-field">
            <span>{gettext("Federation")}</span>
            <select name="fed">
              <option value="">{gettext("All federations")}</option>
              <option
                :for={federation <- @federations}
                value={federation}
                selected={@filters.fed == federation}
              >
                {federation}
              </option>
            </select>
          </label>

          <label :if={@clubs != []} class="filter-field">
            <span>{gettext("Club")}</span>
            <select name="club">
              <option value="">{gettext("All clubs")}</option>
              <option :for={club <- @clubs} value={club} selected={@filters.club == club}>
                {club}
              </option>
            </select>
          </label>

          <label :if={@teams != []} class="filter-field">
            <span>{gettext("Team")}</span>
            <select name="team">
              <option value="">{gettext("All teams")}</option>
              <option
                :for={{no, label} <- @teams}
                value={no}
                selected={@filters.team == to_string(no)}
              >
                {label}
              </option>
            </select>
          </label>

          <label class="filter-field">
            <span>{gettext("Name")}</span>
            <input
              type="search"
              name="q"
              value={@filters.q}
              placeholder={gettext("Find a player…")}
              maxlength="100"
              autocomplete="off"
            />
          </label>

          <label :if={@sort?} class="filter-field">
            <span>{gettext("Sort by")}</span>
            <select name="sort">
              <option value="rank" selected={@filters.sort == "rank"}>{gettext("Rank")}</option>
              <option value="rating" selected={@filters.sort == "rating"}>{gettext("Rating")}</option>
              <option value="name" selected={@filters.sort == "name"}>{gettext("Name")}</option>
              <option value="federation" selected={@filters.sort == "federation"}>
                {gettext("Federation")}
              </option>
            </select>
          </label>

          <div class="filter-actions">
            <button type="submit" class="filter-submit">{gettext("Apply")}</button>
            <a
              :if={FilterParams.active?(@filters) or @filters.sort != "rank"}
              href={@action}
              class="filter-clear"
            >
              {gettext("Clear filters")}
            </a>
          </div>
        </fieldset>
      </form>

      <p :if={@empty?} class="empty filter-empty">
        {gettext("No players match these filters.")}
        <a href={@action}>{gettext("Clear filters")}</a>
      </p>
    </div>

    <%!-- Progressive enhancement only - see the moduledoc. Registered on
          `document`, from whichever render of this component happens to run
          first (a real page load always runs it; an innerHTML swap from the
          20-second refresher never does - see the root layout), so it
          survives every later swap without needing to run again itself: the
          listener re-queries the live DOM each time, the same pattern
          `index.html.heex`'s own search script uses for the same reason. --%>
    <script>
      (() => {
        const init = () => {
          const form = document.querySelector("[data-filter-form]");
          if (!form) { return; }

          // A control changing submits the form for real - a normal
          // navigation to the same GET the button already performs, never a
          // fetch. `requestSubmit` (not `.submit()`) so the button's own
          // `click`/`submit` events still fire, which is what a reader's
          // browser extensions or password manager would expect either way.
          form.querySelectorAll("select").forEach((select) => {
            select.addEventListener("change", () => form.requestSubmit());
          });

          // Debounced, and only once the reader has paused - not on every
          // keystroke, which would submit and reload the page mid-word.
          let timer = null;
          const search = form.querySelector('input[name="q"]');
          if (search) {
            search.addEventListener("input", () => {
              if (timer) { clearTimeout(timer); }
              timer = setTimeout(() => form.requestSubmit(), 500);
            });
          }
        };

        init();
        document.addEventListener("openresults:updated", init);
      })();
    </script>
    """
  end
end
