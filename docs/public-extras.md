# Printing, feeds, embeds and the sitemap

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
