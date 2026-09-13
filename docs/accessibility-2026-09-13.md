# Accessibility pass - 2026-09-13

First look at this dimension. The whole-codebase audit of 2026-09-05 listed
accessibility under "what this audit never looked at", and nothing had looked
since. Target: **WCAG 2.2, level AA**. This site matters most of the two: its
readers are the public, on phones and on a hall's projector, with no account
and nobody to ask.

Scope: every public page (front page, standings before and after round 1,
cross-table, round, projector view, player page, player history, changelog,
entry form, report form, and the refusal and outcome pages), the root layout's
scripts (theme picker, player card, 20-second refresher, FIDE search), the
standings sort/filter script, the projector script, all six themes, and - as a
lower priority, English-only - the admin panel.

## How it was checked

- **A test walks every page.** `test/support/a11y.ex` holds the decidable
  invariants; `test/openresults_web/accessibility_test.exs` renders every
  public GET route from the router in each state that changes its markup
  (English, Dutch, French; swiss and Keizer; before round 1; the projector; the
  forms sent back with their errors; the rate-limit refusal) plus every admin
  page, and fails on any violation. Its first run found over 300 violations
  across 35 public renders, and a skip link, captions and header scopes
  missing on every admin page; that inventory is the spine of the findings
  below.
- **Contrast is computed, not judged.** `test/openresults_web/contrast_test.exs`
  reads the theme tokens out of `assets/css/app.css` and applies the WCAG
  relative-luminance formula to every pairing the stylesheet draws.
- **Scripts were syntax-checked** by rendering the four pages that carry them
  and running each inline script through `node --check`.
- **No browser was driven**, headless or otherwise: axe-core is not available
  on this machine without downloading it. What only a browser and a person can
  confirm - focus actually landing, NVDA actually speaking - is the manual
  checklist at the end.

## Findings, worst first

### 1. The refresher took a keyboard or screen reader user's place away · FIXED

`lib/openresults_web/components/layouts/root.html.heex` (the body script,
"keeping the page current").

On every real update the refresher replaced `#live-region`'s HTML wholesale.
Replacing a node that has focus drops focus to `<body>`, so a keyboard user on
a sort button, a filter or a player's name was sent back to the top of the
document - every time a result came in, which during a round is every few
minutes. In the same swap: an open tie-break `<details>` closed, a cross-table
scrolled to round 9 jumped back to round 1, the front page's search box lost
what had been typed (and its filter), and a sorted standings table went back
to rank order (`standings_script/1` kept the sort inside `init`, which the
update re-runs). If the swap landed while a filter dropdown was open, the
dropdown was pulled out from under the reader.

Fixed without changing what the refresher is:

- before swapping it records where focus is, which `<details>` are open, the
  page tables' horizontal scroll and any typed search, and puts all of it back
  afterwards (`locate`/`relocate` find "the same" element in the fresh HTML by
  its identifying attributes; each tie-break `<details>` now carries a
  `data-detail` key for this);
- the sort lives outside `init` and is re-applied after an update;
- a poll is skipped while an `input`, `select` or `textarea` inside the region
  has focus, and tried again 20 seconds later.

Scroll position of the page itself was already kept (it is a swap, not a
reload). What is **not** kept is NVDA's browse-mode cursor when it sits on a
node that changed; see recommendation R1.

### 2. Nothing the scripts said was announced · FIXED

`#live-status` ("updated just now", "not updating - connection lost") and the
standings filter's "Showing 4 of 32" were `aria-live="polite"` elements
rendered `hidden`. A region that is not in the accessibility tree when its text
arrives is, in practice, not read out; the filter count was also inside the
region the refresher replaces, so it was a brand-new node on every update. The
FIDE search's results and its "No match" line, a sort, and the front page's
"No tournaments match your search." had no announcement at all.

Fixed with one persistent `#announcer` (`visually-hidden`, `aria-live=polite`,
`aria-atomic`) at the top of `<body>`, outside the refreshed region, and a
`window.openResultsAnnounce` helper in the head script. Visible text is
unchanged; the scripts now say, through the announcer: an update or a lost
connection (the latter once, not every poll), the filter count after a change
or Reset, "Sorted by Points, descending" after a header click, the FIDE
search's outcome and "Filled in from the FIDE list...", the empty-search
sentence when it appears, and the projector's paused line. The audit now
refuses a live region rendered `hidden` (`:hidden_live_region`).

### 3. The player card was a dialog in name only · FIXED

Same file. `role="dialog" aria-modal="true"` was right, but focus never moved
into it, Tab walked out into the page behind (which `aria-modal` had just told
a screen reader was not there), and closing it left focus at the top of the
document. It opens on right-click - and, from the keyboard, on the
context-menu key or Shift+F10 on a focused player name, which send the same
`contextmenu` event.

Now: focus moves to the dialog on open (announced as "Player card, dialog"
while it loads, `aria-busy` on its body), then to the player's heading once the
card arrives; Tab and Shift+Tab cycle inside it; Escape (only while open), the
Close button and a click outside close it, and focus returns to the name it was
opened from - or to the same name in the fresh HTML if the refresher replaced
it meanwhile. The redundant `aria-label="Close"` on a button reading "Close"
went. The left-click path is unchanged and remains the no-JavaScript, phone and
keyboard-default route to the same content.

### 4. No skip link and no main landmark on any page · FIXED

All 35 page renders. Keyboard users tabbed through the brand, three language
links and the theme picker on every page before reaching the content; screen
reader users had no `<main>` to jump to, and the masthead bar was a plain
`<div>`.

Now: a "Skip to content" link is the first focusable element (visible on
focus), `#live-region` sits inside `<main id="main" tabindex="-1">` (outside
the swapped region, so the target never disappears), and the masthead bar is a
`<header>`. The admin panel got the same skip link to its existing
`<main id="admin-main">`. New msgid, translated.

### 5. Withheld text was 2.3-3.1:1 in four themes · FIXED (token change)

`--withheld` colours real text: an unpublished round's chip, a card-table row
"not published", a tie-break contribution that did not count, the hyphen for a
result not yet in, the changelog's "Removed" tag and two admin statuses. On
Paper it was 2.30:1. Each value moved only as far as 4.5:1 against both
`--bg` and `--panel` needs, keeping its hue (HSL hue and saturation held,
lightness walked). The dashed chip border and the words beside each use still
mark "set aside".

| Theme | Before | After | On `--bg` | On `--panel` |
|---|---|---|---|---|
| Paper (and Match device, light) | `#a8a8a4` | `#74746f` | 2.30 → 4.54 | 2.39 → 4.70 |
| Night (and Match device, dark) | `#63656b` | `#83868d` | 3.08 → 4.92 | 2.83 → 4.53 |
| Board | `#a39982` | `#746a55` | 2.40 → 4.54 | 2.64 → 4.99 |
| Slate | `#5a6675` | `#7a8899` | 3.10 → 5.02 | 2.80 → 4.53 |
| High contrast | `#555555` | unchanged | 7.46 | 7.46 |

No other token changed. On Board the new withheld sits close to `--quiet`
(4.54 against 4.64); that is the price of the 4.5 floor there, and the one
place a reader might notice the change.

### 6. Text boxes and dropdowns had no visible edge · FIXED

Every input, select and textarea was edged in `--rule`, 1.33-1.46:1 against
the ground (WCAG 1.4.11 asks 3:1 for the boundary that identifies a control).
On Paper a white box on an off-white page had nothing else to see it by. They
are edged in `--quiet` now (4.64:1 or more in every theme): the front page's
search, the standings filters, both forms, the FIDE search and the admin
filters. `--rule` still draws every hairline between rows, where it is
decoration.

### 7. Focus was the browser's own ring · FIXED

No rule drew focus; browsers' default blue is faint on Night and Slate. A
single `:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px }`
now covers everything, at 6.45:1 or more in every theme. The only places the
ring is removed are targets focus is *moved to* that are not controls: `#main`,
`#admin-main`, the card dialog, its heading, and the refused form's alarm. The
contrast test holds that list.

### 8. Tables had no names, header-less tables sat inside cells, and rows had no headers · FIXED

`lib/openresults_web/controllers/tournament_html.ex`.

- No data table had a `<caption>` or name (113 in the walk). Each now has a
  visually hidden caption, reusing existing sentences: "Standings after round 5
  of Gent Open.", "Cross-table", the round's heading, "Byes", "Round by round",
  the tie-break's own label; one new msgid, "Tie-breaks", for the player's
  summary.
- The working table inside every tie-break cell's `<details>` had no header
  cells (90). It has a `<thead>` whose words are visually hidden and whose row
  takes no height.
- Rows had no header: the player (standings, starting rank, cross-table, byes),
  the board (pairings, projector) and the round (card, working tables) are
  `<th scope="row">` now, styled exactly as the cell they replaced
  (`th.row-head`). Moving along a row, NVDA says whose numbers they are.
- Column headers already had `scope="col"`, and the sortable ones were already
  real `<button>`s with `aria-sort` set by the script.
- The cross-table's pinned columns could cover a cell a keyboard had just
  tabbed back to (WCAG 2.4.11); its scroller has `scroll-padding-left` the
  width of both.
- The changelog's markdown tables get `scope="col"` from `OpenResults.Markdown`.
- Admin tables: captions and `scope` added, and the empty action column header
  says what it is.

### 9. Form errors, required fields and the refused form · FIXED

`registration_html.ex`, `report_html.ex`.

The entry form's fields were in good shape (labels, `aria-describedby` hint and
error, `aria-invalid`). Gaps:

- the bye checkboxes' error and hint were tied to nothing - the `<fieldset>`
  now carries them;
- the report form's reason error was tied to nothing, the reason group was not
  announced as required, and the details textarea's error and `aria-invalid`
  were missing - all added (`required` on the radios, which the server already
  demanded);
- "required" was read twice ("Name required, edit, required") - the visible
  word is `aria-hidden`, the input's `required` attribute speaks;
- `aria-describedby` read the hint before the error; the error comes first
  now, as on screen;
- a refused form reloaded with the reason at the top and focus nowhere - the
  alarm ("Nothing has been sent...") takes focus on load (`tabindex="-1"`,
  `role="alert"` kept for the no-JavaScript case);
- the FIDE search's hint was not tied to its box (`aria-describedby`);
- birth year gets `autocomplete="bday-year"` (WCAG 1.3.5).

### 10. Meaning that lived only in a `title` · FIXED

A hyphen for "not yet reported" (pairings, cross-table) or "an earlier round is
not public" (running scores), and an empty cross-table cell meaning "no game
published for this round", explained themselves only in `title` - which a
screen reader does not read on a plain span and a phone cannot show. The glyph
is now `aria-hidden` beside visually hidden words (`said_as/1`); the empty cell
carries its sentence visually hidden. `title`s kept for the mouse.

### 11. Which page you are on, and what a round link is called · FIXED

The round strip marked the current page by accent and weight only; it now says
`aria-current="page"`. Round links in the strip and the cross-table's headings
were named "3"; they are "Round 3" (or "M2-1, Match 2, game 1" for match
format - the visible label always leads, WCAG 2.5.3). The footer's build link
was named "Changelog" by `aria-label`, hiding the version it displays from a
screen reader and from speech input; it is now the version followed by a
visually hidden "Changelog".

### 12. The theme picker · FIXED

The current theme was a CSS highlight only; each option now has `aria-pressed`,
kept in step by the script. Choosing a theme closed the popover and dropped
focus with the hidden option; focus returns to the trigger. Escape closes it.

### 13. Reflow at 320px · FIXED

At 320 CSS px (a small phone, or 400% zoom on a 1280px window) the masthead bar
did not wrap and pushed the page sideways; it wraps now, with the tools kept
right so the theme panel still opens into the page. A player's tie-break
summary ("from 9 rounds, 1 discarded, 2 unplayed") could not wrap. Long
unbroken words break instead of overflowing (`overflow-wrap` on `body`; cells
that set `nowrap` are unaffected). Tables scroll inside `.scroller`, which WCAG
1.4.10 allows for two-dimensional data.

### 14. The changelog page had two `<h1>` · FIXED

`CHANGELOG.md`'s own "# Changelog" rendered under the page's heading of the
same name. `OpenResults.Changelog` drops the file's title.

## Recommended, not built

### R1. Let a reader pause live updates, and change less of the page when they arrive

Finding 1 restores focus and state, but an update still replaces every node in
the region, and NVDA's browse-mode cursor - which is not focus - resets when the
node under it goes. WCAG 2.2.2 (Pause, Stop, Hide) arguably also applies to a
page that rewrites itself every 20 seconds; the counter-argument is that live
results are the point of the page.

Plan, in two independent parts:

1. **A pause control** in the footer beside `#live-status`: a `<button
   aria-pressed>` "Pause live updates" / "Resume", shown only with JavaScript
   (`has-js`), remembered per tab in `sessionStorage`; the refresher's `tick`
   returns early while paused. Two msgids per language. **Size: small** (half a
   day with translations and a markup test).
2. **Morph instead of replace**: walk the old and fresh region together and
   change only differing text nodes and attributes, replacing a subtree only
   where the structure differs (a ~80-line keyed morph, keyed on the same
   identifying attributes `locate` uses). Unchanged rows then keep their nodes,
   so focus, `<details>`, scroll and the screen reader's cursor all survive
   without being restored. **Size: medium** (1-2 days, most of it testing the
   standings, cross-table and front page by hand with NVDA).

### R2. Dark native controls on the dark themes

Night and Slate do not set `color-scheme: dark`, so a `<select>`'s open list,
scrollbars and checkboxes render in light system style on a dark page. Not an
AA failure (they stay readable), but jarring. **Size: tiny** - `color-scheme`
per theme block, checked in both browsers.

### R3. The federation field's autofill

`autocomplete="country"` offers the browser's two-letter country code ("BE")
to a field that wants a three-letter FIDE code ("BEL"). Either drop the token
or translate ISO-2 to FIDE on the server. **Size: small.**

### R4. The score chart's "not counted" bars

A contribution that did not count is drawn in `--withheld` at 30% opacity
against counted ones in the accent at 28% - told apart by colour alone. The
same facts are in the working tables directly underneath, so nothing is lost
(the chart has a text alternative and the data is on the page), but a hatch
pattern or an outline on the uncounted bars would make the chart itself
readable without colour. **Size: small.**

## Checked and clean

- `<html lang>` follows the resolved locale on every page, in every language
  (asserted for `en`, `nl`, `fr`); language links carry `lang` and `hreflang`.
- One `<h1>` per page and no skipped heading levels (after finding 14).
- Every form control has a label; no `placeholder` stands in for one.
- No `<img>` on the public pages; the logo SVG is `aria-hidden`; the score
  chart is `role="img"` with a translated `<title>`.
- No `tabindex` above 0; no duplicate ids; every `for`, `aria-describedby`
  and `aria-labelledby` resolves.
- Sortable headers are `<button type="button">` inside `th[scope=col]`, with
  `aria-sort` on the header.
- `prefers-reduced-motion`: the projector's progress bar is the only animation
  and is hidden; nothing else transitions. The projector's automatic paging
  (every 12 seconds) pauses on a tap or Space and says how to resume.
- Target size (WCAG 2.5.8): the smallest targets - a cross-table opponent
  number, the "#" sort button, the build link - meet the spacing exception;
  every other control is 24px or more.
- Zoom: `viewport` does not restrict scaling; type is in `rem`.
- The projector view (`?display=1`) forces the High contrast theme; it is a
  hall-screen presentation of the round page and is not meant to reflow at
  320px - the ordinary round page is the phone's version.

## Tests added

- `test/support/a11y.ex` - `OpenResultsWeb.A11y.audit/2`, the invariants: `lang`
  (and that it matches the locale asked for), a `<title>`, one `<h1>`, heading
  order, one `<main>`, a skip link first, a name for every form control, link,
  button and `<summary>`, `alt` on every `<img>`, SVGs hidden or named, header
  cells with `scope` in every table, a caption or name on every table, no
  positive `tabindex`, no dangling id references, no duplicate ids, dialogs
  named and modal, nothing focusable under `aria-hidden`, no live region
  rendered `hidden`.
- `test/openresults_web/accessibility_test.exs` (8 tests) - every public page
  walked from the router in every state that changes its markup, both forms
  sent back refused (in three languages for the entry form), the rate-limit
  refusal, every admin page; plus the markup the scripts depend on: the
  announcer outside the refreshed region, sort buttons inside column headers,
  a unique key on every tie-break `<details>`, the card dialog focusable.
- `test/openresults_web/contrast_test.exs` (5 tests) - every theme defines all
  seven tokens; every pairing the stylesheet draws meets its AA ratio in every
  theme; no text box or dropdown is edged in `--rule`; the focus ring exists
  and is hidden only on the listed non-controls; the formula against WCAG's
  reference values.
- Existing tests updated where the markup deliberately changed: row headers
  are `th` (selectors `td` → `> *` or `th.xt-name`), hidden words beside a
  hyphen or in an empty cell, the admin panel's dead-link walk skips the
  in-page skip link.

## Manual checklist

What only a person, a browser and a screen reader can confirm. Chrome or Edge
plus Firefox; NVDA 2024+ on Windows. Clear the page cache (restart the dev
server) before judging a template change.

### Keyboard only (no mouse at all)

1. **Front page.** Load `/`. First Tab shows "Skip to content" in the top
   left; Enter moves focus past the masthead (the next Tab lands in the search
   box). Type a few letters; the list filters. Leave focus in the box for over
   20 seconds while an arbiter republishes: nothing is replaced under you; Tab
   out and within 20 seconds the list updates, the search text is still there
   and still applied.
2. **Standings.** Open a tournament. Tab to a column heading ("Points"); Enter
   sorts, again reverses; the arrow appears. Tab to the Club filter, pick a
   club with the arrow keys; rows filter and "Showing X of Y" appears. Have
   the arbiter publish a result: within 20 seconds focus is still on the
   element you left it on (a heading, a name), the sort and filter still hold,
   the page has not scrolled.
3. **Tie-break working.** Tab to a tie-break value, Enter opens it; after an
   update it is still open.
4. **Player card.** Tab to a player's name, press the context-menu key (or
   Shift+F10). The card opens with focus inside; Tab cycles Close and the
   card's links without leaving it; Escape closes it and focus is back on the
   same name.
5. **Cross-table.** Scroll the table sideways with Tab through the round
   headings and opponent numbers: no focused link hides under the pinned
   number and name columns. After an update the table is still scrolled where
   you left it.
6. **Theme picker.** Tab to "Theme", Enter opens it, Tab to an option, Enter
   applies it; the popover closes and focus is on "Theme". Open it again and
   press Escape: it closes. Every focused control in every theme shows the
   accent ring.
7. **Entry form.** `/t/<slug>/register`. Tab through every field; labels,
   hints and "required" make sense. Submit empty: the page reloads with focus
   on "Nothing has been sent...", and Tab goes to the first field. With the
   FIDE search configured, type a name, Tab into the results, Enter on one:
   fields fill and focus lands on Email.
8. **Report form.** Submit without a reason: the browser asks for one (the
   radios are required). Fill it, send, read the confirmation.
9. **Projector.** `/t/<slug>/round/<n>?display=1` on a round with more boards
   than fit: Space pauses, the paused line appears, Space resumes.

### NVDA - the public standings page

Browse mode unless stated. Language set to Dutch once, French once.

1. Load the standings. NVDA reads the page title; `H` lists one level-1
   heading (the tournament) and a level-2 "Standings after round N"; `D` lists
   landmarks: banner, navigation "Language", navigation "Rounds", main,
   content info.
2. In the round strip, the current page is announced as "current page"; a
   round link reads "Round 3, link", an unpublished round "3, not published".
3. `T` to the table: NVDA announces the caption ("Standings after round 5 of
   ..."), and the row and column count. Ctrl+Alt+Down through the Points
   column: each cell is read with the player's name (row header) and "Points".
4. A column heading reads as "Points, button" inside its column header; press
   it (Enter in focus mode or NVDA+Space): you hear "Sorted by Points,
   ascending", and the header reads "sorted ascending".
5. Change the Club filter: "Showing 4 of 32" is spoken. Reset: "Showing 32 of
   32".
6. A tie-break value reads "1.5 show how this was reached, collapsed"; opening
   it and arrowing in reaches a small table with its caption and "Rd, From,
   Value" headings.
7. On a round page, a result not yet in reads "not yet reported" (not "dash").
8. Wait for an update with the arbiter publishing: "updated just now" is
   spoken once. Pull the network: after two polls, "not updating - connection
   lost", once.
9. Context-menu key on a name: "Player card, dialog", then the player's name
   as a heading. Escape: back on the name.
10. Note anything read in the wrong language, and anything read twice.

### Look and reflow

- Every theme (Paper, Night, Board, Slate, High contrast, Match device in both
  OS modes): withheld round chips, card rows "not published" and uncounted
  working rows are legible and still read as set aside; text boxes have an
  edge; the focus ring is visible.
- 320px wide (DevTools device toolbar) and 400% zoom at 1280px: no page scrolls
  sideways except inside a table's own scroller; the masthead wraps with the
  theme picker on the right, and its panel opens on screen.
- 200% text zoom (browser text-only zoom in Firefox): nothing clipped or
  overlapping.
- `prefers-reduced-motion` on: the projector's bar is gone, the page counter
  still turns.
