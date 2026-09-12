# Browser-side review, 2026-09-12

Every piece of code that runs in a reader's browser, reviewed against seven
failure modes: re-render survival across the 20-second refresher, leaks,
state assumptions, sort/filter/search correctness, injection, progressive
degradation, and console noise/dead code. Nobody had looked at this half of
the app before - a whole-codebase audit in September explicitly flagged
"browser-side JavaScript and LiveView hooks" as never reviewed.

## What was inventoried

There is no LiveView anywhere in this app (`grep` for `phx-hook`,
`ColocatedHook`, `live_render` and `use Phoenix.LiveView` in the router and
templates comes back empty), so the entire client-side surface is four
places:

1. `lib/openresults_web/components/layouts/root.html.heex` - two inline
   `<script>` blocks: the theme bootstrap in `<head>` (lines 49-106) and the
   body script (lines 227-530) that owns the theme switch, the player-card
   overlay, the 20-second refresher, the FIDE-search autocomplete, and the
   right-click handler.
2. `lib/openresults_web/controllers/tournament_html/index.html.heex` - the
   front page's tournament search (lines 77-122).
3. `lib/openresults_web/controllers/tournament_html.ex` - the standings
   table's sort/filter script (now `standings_script/1`, was inline inside
   `standings_table/1`) and the projector round's pagination/cycling script
   (`projector_round/1`, lines 1367-1548).
4. `assets/js/app.js` - the esbuild-compiled bundle. **It is dead code**: no
   template anywhere emits a `<script src="/assets/js/app.js">` tag (checked
   every `.heex` file and `root.html.heex` specifically), so the LiveSocket
   connection, the topbar progress bar and the dev-mode live-reload helpers
   it sets up never run in this app. See finding 4 below.

## Findings, worst first

### 1. FIXED - the standings sort/filter script never registered before round 1

**File:** `lib/openresults_web/controllers/tournament_html.ex` (was inside
`standings_table/1` around old line 419; now `standings_script/1`, lines
447-617) and `lib/openresults_web/controllers/tournament_html/standings.html.heex:19-24`.

**What broke:** `standings.html.heex` renders `starting_rank_table/1` while
`Tournament.starting_rank?/1` holds (players entered, round 1 not published
yet - the normal state of every tournament for at least a while after it is
first listed) and `standings_table/1` once that stops holding. The sort and
filter `<script>` lived *inside* `standings_table/1`'s own template, so on
any page load that started in the starting-rank state, that script never
ran at all - `document.addEventListener("openresults:updated", init)` was
never registered. When the arbiter then published round 1 and the root
layout's 20-second refresher swapped in the real standings markup (sort
buttons, filter `<select>`s, the lot), nothing was listening for that swap.
The newly-arrived controls sat there completely inert - no click handler on
the sort buttons, no filter wiring, no URL-driven pre-selection - until the
reader manually reloaded the page. This is exactly the re-render-survival
contract the task called out as the thing to check most carefully, and it
was broken for the single most common transition on the whole site.

The front page's own search script (`index.html.heex`) already gets this
right: it renders unconditionally regardless of whether any tournaments are
published yet, and `init()` just returns early if its elements are not
there. That is the pattern this fix copies.

**Fix:** extracted the script into its own function component,
`standings_script/1`, with no dependency on `standings_table/1`'s own
`:if`, and call it unconditionally from `standings.html.heex` right after
both conditional table branches. `init()` already tolerated the table's
absence (`if (!tbody) { return; }`), so on the starting-rank render it now
simply registers the listener and does nothing else, and is armed the
moment a later refresh brings the real table in.

**Tested:** `test/openresults_web/standings_sort_filter_test.exs`, new
`describe "the script re-registers on the refresher regardless of which
table renders"` block (two tests). One publishes a tournament with players
but an empty `standings.rows` (the starting-rank state) and asserts the
script carrying `data-standings-panel` and the
`addEventListener("openresults:updated", init)` call still ships; the other
guards against the extraction introducing a duplicate script on an ordinary
page. Verified the first test actually fails against the pre-fix code (by
temporarily reverting the two source files and re-running) before restoring
the fix - it does, with `expected the standings sort/filter script to
render even before round 1`.

### 2. FIXED - `history.replaceState` unguarded, could take the sort buttons down with it

**File:** `lib/openresults_web/controllers/tournament_html.ex:524-534`
(inside `standings_script/1`, function `applyFilters`; the call itself is
line 530).

**What could break:** `applyFilters()` ends by calling
`history.replaceState(...)` to reflect the active filters in the URL. In a
sandboxed iframe without `allow-same-origin` - the exact "club site embed"
scenario this app's own theme script already guards `localStorage` for two
screens up - `history.replaceState` throws a `SecurityError` synchronously.
Because `applyFilters()` is called once, unconditionally, near the *start*
of `init()` (line ~508, before the "---- sorting ----" section), an
uncaught throw there would abort the rest of `init()` outright - meaning
the sort-button click handlers defined afterward would never be attached
either. A single unguarded browser API call could silently disable both
filtering and sorting together, on exactly the embed case this site is
built to support.

**Fix:** wrapped the `history.replaceState` call in `try/catch`, matching
the existing `localStorage` guard style elsewhere in this codebase. The
filter still applies to the rows on screen if the call throws; only the
shareable-URL side effect is lost, and the rest of `init()` keeps running.

**Not separately tested:** this is a pure runtime/browser-API behavior with
no server-observable signal (the rendered HTML is identical either way) -
see the manual checklist below.

### 3. RECOMMENDATION (not fixed) - the FIDE-search box is not gated behind `has-js`

**File:** `lib/openresults_web/controllers/registration_html.ex:74-91`
(`.fide-search` markup) vs. `lib/openresults_web/components/layouts/root.html.heex:377-499`
(the script that drives it).

Every other JS-only control on the site (`.index-controls`,
`.standings-controls`, the sort buttons' clickable styling) is hidden by
CSS (`assets/css/app.css:399-520`) until `html.has-js` says the script that
drives it actually ran - the whole point being that a visitor with no
JavaScript never sees a control that silently does nothing. The FIDE-search
box is the one exception: it always renders, with no `has-js` gate in
`app.css`. Without JavaScript, typing a name into it does nothing at all -
no error, no fallback, just silence - while the ordinary form fields two
inches below it work fine. This is a real gap against the stated
progressive-degradation contract, but closing it (hiding the box behind
`has-js`) is a visible behavior change for exactly the no-JS visitors this
matters most for, and I did not want to make that call unilaterally. Left
as a recommendation: either gate `.fide-search` behind `html.has-js` like
every other JS-only control, or add a one-line static hint under the label
("only works with JavaScript") for the no-JS case.

### 4. RECOMMENDATION (not fixed) - `assets/js/app.js` is entirely dead code

**File:** `assets/js/app.js` (whole file); referenced from
`config/config.exs:42` (the esbuild build step) and
`lib/openresults_web/endpoint.ex:14` (the `/live` socket mount); never
referenced from any `.heex` template.

The scaffold's `app.js` - LiveSocket connection, topbar progress bar,
dev-mode live-reload keyboard shortcuts - is compiled by esbuild into
`priv/static/assets/js/app.js` on every build, but no template anywhere
emits a `<script src=...>` tag for it (confirmed by grepping every
`.heex` file for `app.js`, `assets/js` and `<script src`). It has never
run in this app. This isn't a bug today - dead code that never loads does
no harm - but it is confusing: a future contributor could reasonably expect
editing `app.js` to change something, and the esbuild/LiveView machinery it
implies (the `/live` socket stays mounted at the endpoint level, see
`endpoint.ex:14`) is pure overhead for an app whose whole design point is
"no bundle, no socket, no framework" (root layout's own comment,
`root.html.heex:37-38`). Recommend either deleting `app.js` and the esbuild
step entirely, or - if LiveView is genuinely planned for later - a comment
at the top of `app.js` saying so. Not fixed here: removing a build step is
a structural decision outside a browser-code safety pass.

### 5. RECOMMENDATION (not fixed) - alphanumeric category codes do not get a natural sort

**File:** `lib/openresults_web/controllers/tournament_html.ex:582-587`
(inside `standings_script/1`, the `applySort` comparator).

The sort comparator tries `parseFloat` on both values and falls back to
`localeCompare` only when at least one side is not a plain number. A
category code that mixes letters and digits in the *other* order (a bare
`"18"` rather than `"U18"`) parses as a number and sorts numerically
(harmless and arguably correct); one that starts with a letter, like a
`"U8"`/`"U10"` age-category pair, falls through to `localeCompare` and
sorts lexicographically - `"U10"` before `"U8"`, since `"1" < "8"`
character-by-character, which reads wrong to anyone expecting age order.
This is a pre-existing, narrow correctness gap (only affects category/text
columns whose values mix letters and digits with different lengths) and
fixing it means adding a natural-sort comparator, which changes sort output
for existing tournaments in ways I could not verify against every
real-world category naming scheme this app has seen. Recommended, not
fixed.

### 6. Noted, not a finding - `<.table>` scaffold component is unused dead markup

**File:** `lib/openresults_web/components/core_components.ex:378`
(`phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}`).

This is the `mix phx.new` scaffold's generic `<.table>` component, built
for a LiveView stream. Nothing in `lib/` calls it (`grep` for `<.table` and
`CoreComponents.table` outside its own definition is empty), and since
there is no LiveView in this app at all (finding 4), the `phx-update`
attribute it emits is inert wherever it might theoretically be used. Not a
browser-code safety issue - it renders nothing today - just worth flagging
alongside `app.js` as scaffold left in place after the app's shape changed
around it.

## What was checked and found clean

For completeness, since the task asked which failure modes were actually
checked for each piece of code:

- **Injection (failure mode 5):** every place client JS builds DOM from
  data uses `textContent` (the FIDE-search results list,
  `root.html.heex:415-448`, `render()`) or moves already-parsed,
  already-escaped DOM
  nodes (`replaceChildren`/`innerHTML` assignment from a `DOMParser` result
  of this site's own re-fetched, HEEx-escaped HTML - the refresher's
  `swap()`, the projector's `refreshRows()`, and the player-card overlay's
  right-click handler, all in `root.html.heex`). None of them string-concatenate
  tournament or player data into HTML. No injection findings.
- **Leaks (failure mode 2):** every `setInterval`/`setTimeout` that gets
  replaced is cleared first (`scheduleCycle`'s `clearInterval`, the debounce
  `clearTimeout` in the FIDE search and in the projector's resize handler);
  the ones that are not cleared (the refresher's own 20s tick, the
  projector's 60s row-refresh) are registered exactly once per real page
  load, by design, and are meant to run all day. No leak findings beyond
  what is already listed above.
- **Double-binding across the refresher (failure mode 1):** checked every
  script that touches `#live-region`'s swapped content. Both the front-page
  search and (after the fix) the standings script re-query the DOM inside
  their `init()` on every `openresults:updated` event rather than closing
  over stale references, and since the refresher does a full
  `innerHTML` replacement of the region, every element `init()` binds a
  listener to on a given run is a brand-new node that has never been bound
  before - there is no path to a double-bound listener on the same element.
  The one gap was finding 1, which was a *missing* registration, not a
  duplicate one.
- **State assumptions / null checks (failure mode 3):** every
  `querySelector`/`getElementById` result that is not structurally
  guaranteed by its own enclosing `:if` is null-checked before use (the
  index search, the standings panel/controls, the card overlay). All four
  `localStorage` call sites were already wrapped in `try/catch`. The one gap
  was finding 2 (`history.replaceState`), now fixed.
- **Console noise / dead code (failure mode 7):** no `console.*` or
  `debugger` statements anywhere in `lib/` or `assets/`. Findings 4 and 6
  are dead-code items, both scaffold leftovers rather than anything the
  browser-review's own script bodies introduced.

## Manual browser checklist

A few minutes of clicking, covering what ExUnit cannot exercise:

- [ ] Open a tournament's standings page before round 1 (starting-rank
      table showing), leave the tab open, and have the arbiter publish
      round 1 - or simulate it by editing the snapshot's `standings.rows`
      and re-ingesting. Confirm that within 20 seconds the sortable table
      appears **and its sort buttons and filter dropdowns work** without a
      manual reload. (This is the regression finding 1 fixes - the
      server-side test proves the listener is present in the markup, but
      only a browser proves the click actually reorders rows.)
  - [ ] On that same standings page, click a sort header, then a filter
      dropdown, and confirm the count text ("Showing X of Y") and the URL
      query string both update, and clicking the header again reverses the
      order.
  - [ ] Reload a filtered URL (`?club=...`) directly and confirm the filter
      re-applies on load and the table itself renders identically to the
      unfiltered page (same rows, same order) before the script runs.
  - [ ] Load the site in a browser with third-party storage blocked (or a
      private-window equivalent), or embed a tournament page in an
      `<iframe sandbox="allow-scripts">` (no `allow-same-origin`) on a
      throwaway local HTML file, and confirm: the theme still applies (light
      default), the standings sort buttons still work end to end (this
      exercises the `history.replaceState` guard from finding 2 - without
      the fix, sorting would silently stop working entirely in this
      context), and no uncaught exceptions appear in the console.
  - [ ] Right-click a player's name; confirm the card overlay opens, Escape
      and clicking outside both close it, and the close button works.
      Right-click a name, then let the 20-second refresher fire while the
      overlay is open; confirm the overlay is untouched (it lives outside
      `#live-region`).
  - [ ] Toggle the theme picker through all six options and reload the
      page; confirm the choice persists and there is no flash of the wrong
      theme before first paint.
  - [ ] Open the round page with `?display=1` (projector view) on a
      tournament with more boards than fit one screen; confirm it pages
      through them, the progress bar and pause-on-tap/space both work, and
      that the 20-second site-wide refresher visibly does **not** also fire
      here (no blink, no reset of the page/cycle position) while the
      projector's own 60-second row refresh still updates results.
  - [ ] On the front page before any tournament is published (or with the
      list filtered to nothing via search), confirm the "no tournaments"
      messaging shows correctly and typing further in the search box does
      not error.
  - [ ] With JavaScript disabled entirely: confirm the standings table,
      front-page list and pairings all render in full (nothing is hidden
      pending a script that will not run), the sort-header buttons look
      like plain text rather than clickable controls, and the FIDE-search
      box (finding 3) is the one place that looks like a working control
      but silently does nothing when typed into.
  - [ ] Leave a standings page open for several hours (or throttle the
      network to simulate a flaky hall wifi) and confirm the "not
      updating - connection lost" status appears after a couple of failed
      polls and clears once connectivity returns, with no growth in memory
      use from repeated polling (DevTools Performance/Memory tab).
