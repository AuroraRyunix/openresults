# Printing, feeds, embeds, the sitemap and the hall display

None of these compute anything or read anything the pages do not already
show. Each honours the arbiter's display switches the same way the pages do.

## Printing

Print any page from the browser. The print stylesheet (the `@media print`
block at the end of `assets/css/app.css`) forces black on white, hides the
site's own furniture, keeps the tournament's name and the current round chip,
repeats table headers on each sheet and never splits a row.

## The feed - `/t/<slug>/feed.xml`

Atom. One entry per state the tournament has reached, with the state in the
entry id so a feed reader shows each one once:

| id suffix | when |
|---|---|
| `#round-N-pairings` | round N is published, and pairings are shown |
| `#round-N-results` | every board of round N has a result, and its results are public |
| `#standings-N` | the standings reflect round N, and standings are shown |

Every entry carries the current snapshot's time. A hidden tournament's feed is
the same 404 as one that never published.

## A player's board - `/t/<slug>/player/<no>/board`

A redirect to the latest published round, with `#board-B` when the player is
on a board there. 404 for a player not in the tournament; withheld when
pairings are not published.

## Embedding - `?embed=1`

```html
<iframe src="https://results.example.org/t/gent-spring-open-2026?embed=1"
        style="width:100%;height:40rem;border:0" title="Standings"></iframe>
```

Works on any tournament page: standings, a round, the cross-table, a card.
The site's header, the operator's notice, the filter bar and the footer are
left out; one link back to the full page stays. Links open in the whole tab
(`<base target="_top">`). Which sites may frame the page is still decided by
`PUBLIC_FRAME_ANCESTORS` - see `OpenResultsWeb.Framing`.

## The sitemap - `/sitemap.xml`

The front page's tournaments (moderation-visible and listed by their arbiter):
standings, cross-table and each published round, as far as the arbiter
publishes each. Player cards are never listed. `robots.txt` is static and
cannot know this site's host, so submit the sitemap to search engines
directly, or add a `Sitemap:` line to `priv/static/robots.txt` on deploy.

## Year filter on the front page

`/?year=2026`. Offered only when the listed tournaments span more than one
year. A tournament's year is its start date's, and only when its arbiter
shows dates.

## The hall display - `/t/<slug>/hall`

A full-screen page for a television or a projector in the playing hall. No
login, one address per tournament, linked from every round page. Open it in
a browser on the screen's computer and make the window full screen (F11).

It cycles through, a page at a time:

1. **Pairings** of the current round - the newest published one - twelve
   boards a page, with results as they arrive (team matches for a team
   event paired by matches);
2. **Find your board** - every player in the round alphabetically (accents
   ignored), with board and colour, 28 names a page and the letters each page
   covers ("Names A to De");
3. **Results** - how many are in, and the latest twelve, newest first; a
   result that arrived while the screen was on is marked for five minutes;
4. **Standings** - the top N, twelve a page;
5. **Announcement** - the arbiter's text, when there is one.

A view with nothing to show is skipped. The header carries the tournament's
name, the round and its date, a "Final round" badge on the last round, and a
clock (the screen's own time). A tap or the space bar pauses on the page
showing; the arrow keys step.

**Holding on a new round.** While the newest round is paired and none of its
results is in, the cycle shows only the pairings, the name list and the
announcement - what everyone in the hall is looking for at that moment. A
newly published round jumps the screen straight to its pairings. The first
result ends the hold.

**Settings** travel from OpenPairings in the snapshot (`tournament.hall`, see
`docs/snapshot-schema.md`), set on its Results-site settings page: each view
on or off, seconds per page (default 15), how many standings rows (default
10), the hold, and the announcement. Two more are for whoever sets up the
screen, in the URL:

| parameter | effect |
|---|---|
| `?theme=light` | the high-contrast light theme; the default is dark |
| `?views=names,pairings` | only these views on this screen - for a hall with two screens. It can only narrow what the arbiter chose |
| `?lang=nl` | the language, as on every page |

**Never more than the public pages.** No pairings, names or results when the
arbiter withholds round pages; no standings when they withhold standings;
no rating, title or federation beside a name when that tick is off; no byes
in the name list when byes are hidden; no result from a round whose results
are not public. A hidden or unknown tournament is the standings page's own
404, and a tournament hidden while a screen shows it leaves the screen.

**How it stays current.** Unlike every other page here, it keeps a
connection open: it is a LiveView on a PubSub topic per tournament
(`OpenResults.TournamentEvents`), told about every publish and every status
change, so a result appears within a second of the arbiter publishing it.
It is not behind the page cache or the ETag revalidation - the socket
re-reads the snapshot itself - and each page turn also checks the snapshot id
(one ETS lookup), so a message lost to a reconnect costs one page, not the
round. No session and no cookie: the socket is declared without session
connect-info (see `OpenResultsWeb.Endpoint`), and the language travels in the
page's signed LiveView session. The reverse proxy must pass WebSockets
through (Cloudflare's tunnel does); LiveView falls back to long polling
where it cannot.

The older projector view (`/t/<slug>/round/<n>?display=1`) is unchanged: one
round's boards, a plain document with no connection.
