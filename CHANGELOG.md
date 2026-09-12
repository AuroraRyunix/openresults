# Changelog

All notable changes to OpenResults are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

OpenResults split off from OpenPairings into its own application on
2026-08-29; from that point the two have separate histories; this file is
only this site's. This file itself, and the version number below, did not
exist until 2026-09-12 - `mix.exs` had said `0.1.0` since the day the
repository was created, through fifty-odd commits and several real
production deploys, because nothing had ever bumped it. Every version below
**0.13.0** is reconstructed after the fact from the repository's own commit
history rather than written at the time it shipped, so the version
boundaries are a judgement call made during that reconstruction, not
something the commits themselves recorded.

Each entry is tagged so a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a vulnerability closed, or judged not to apply |
| [Verified] | checked against a reference, no code change |

## [Unreleased]

- [Feature] **The admin panel's front door: `/admin`, behind Cloudflare
  Access and checked again by the site itself.** Signing in goes through
  Cloudflare Access and Keycloak; the site then verifies the token Access
  attaches (its signature against Cloudflare's published keys, that it was
  issued for this application and this team, that it is current) and checks
  the email against its own list. A mistake in either place alone opens
  nothing. For now the panel is a dashboard saying who is signed in and a
  sign-out link; the moderation pages come with public publishing. It
  exists only when `OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN`,
  `OPENRESULTS_ADMIN_ACCESS_AUD` and `OPENRESULTS_ADMIN_EMAILS` are all set -
  otherwise, and for anyone without a valid Access token, `/admin` is the
  same "Not Found" as a page that does not exist. Setup, checks and
  troubleshooting are in `docs/admin.md`.
- [Security] **Admin pages are never stored, framed, indexed or scripted,
  and destructive actions will always ask first.** Every admin response is
  `Cache-Control: no-store`, refuses to be put in a frame, asks search
  engines to stay away and runs no JavaScript; none of it passes through the
  page cache that serves public pages. Anything that deletes or revokes goes
  through a confirmation page and a form protected against cross-site
  forgery. The public pages keep all of their own behaviour: still
  embeddable, still cached between publishes.
- [Security] **The public site now cannot set a session cookie even by
  mistake.** The session machinery used to be switched on for every
  request, and the public pages stayed cookie-free only because nothing on
  them happened to use it. It now exists on `/admin` alone, in a cookie of its
  own that the browser sends nowhere else.
- [Fix] **Sorting and filtering the standings did nothing on a tournament
  that opened before round 1** until the page was reloaded. The script that
  wires the sort buttons and the filter lived inside the standings table,
  which only renders once there are standings, so a page first opened on the
  starting list never ran it - and the 20-second refresh that later swapped
  in the real table found nothing listening. The script now renders on every
  standings page, and a sandboxed frame that forbids `history.replaceState`
  no longer stops it wiring the buttons.
- [Fix] **Three messages on the entry form were answered in English on
  Dutch and French pages**, even though all three had been translated since
  the day the site learned to speak them: the ones about a name being
  between 2 and 100 characters, an address being too long, and a club name
  being at most 100. The translations were fine; the site was looking them
  up the wrong way, as though they were the kind of sentence that changes
  with a number in it. The form is the one place here where a visitor is
  told they got something wrong, so it is the last place that should have
  been saying it in a language they did not ask for.
- [Fix] **Four French sentences said something other than their English
  originals.** The cross-table's key had the score coming from the
  opponent's side of the board rather than the player's; the player card
  called the arbiter's total "official", which is a claim this site does not
  make anywhere else; the player-history line was missing a word and read as
  broken French; and the hint under the entry form's Elo box used the same
  word this site uses for the standings, so it read as "the standings you
  play under".
- [Fix] **French punctuation spacing.** Fourteen French sentences could
  break a line and leave a colon or a question mark stranded at the start of
  the next one. They now hold the space French typography asks for.
- [Verified] First audit of the translations themselves - all three
  languages, both catalogues, read end to end. Written up in
  `docs/translations-audit-2026-09-12.md`, including what was checked and
  found correct (the page cache serves each language its own pages; every
  placeholder matches; French and Dutch chess vocabulary is the right
  vocabulary) and what is a decision rather than a defect - scores still
  print `5.5` rather than `5,5`, and dates still print `2026-08-29`, in
  every language.

## [0.13.0] - 2026-09-12

- [Feature] **The version number in the footer is now a link to this
  changelog**, in your own language, the same way OpenPairings' does. The
  build stamp after the version (`+<commit>`) still shows exactly what it
  showed before - that part answers "did my deploy land", and clicking it
  changes nothing about that.
- [Fix] **A few hundred people looking at the same tournament at once could
  exhaust this site's database connections**, even though every one of them
  was asking for a page that had not changed. Working out "is there anything
  new" ran a real database query on every single request, including the
  quiet `304 Not Modified` answers that make up most of them; that lookup is
  now kept in memory instead, and only touches the database on a cold start
  or right after a tournament is taken down.
- [Verified] Re-ran the same load test against the fix with nothing else
  changed: the concurrency level that used to fail two out of five requests
  now completes all of them, at roughly four times the throughput.

## [0.12.0] - 2026-09-11

- [Feature] **Before round 1, the standings page now shows the starting
  rank** - every entered player, in starting order - instead of a blank page
  saying nothing has been published yet.
- [Fix] **The cross-table and a player's own card could show a round's live
  results before the arbiter had folded them into the published standings.**
  Both now stop at whichever round the standings actually cover, matching
  what the arbiter chose to publish rather than whatever has been typed in
  so far.

## [0.11.0] - 2026-09-11

- [Feature] **The front page now sorts every published tournament into Live,
  Upcoming and Finished**, worked out from each tournament's own dates and
  how many rounds it has published, and gains a search box over the list.
- [Fix] **Clicking a column header to sort the standings could scramble the
  table instead of reordering it, and the Rating column's own sort did
  nothing at all.** Both are fixed; found by actually clicking them, since
  neither bug could be seen from the test suite alone.

## [0.10.0] - 2026-09-11

- [Feature] **Every tiebreak value on the standings can now be opened**, by
  tap or by keyboard, to see how it was reached rather than only what it is
  - for the tournaments whose arbiter chose to publish that detail.
- [Feature] **A FIDE id is now a link to every tournament that player has
  appeared in on this site**, wherever a FIDE id already appears. Matched by
  id, never by name, since two players can share a name.
- [Feature] **The standings can be sorted and filtered** - by column, and by
  club, federation or category - entirely in your own browser; the page the
  server sends is unchanged either way.
- [Fix] **On a narrow phone screen, the cross-table's pinned name column
  could overlap its own pinned rating column**, hiding a digit of the
  rating or letting a result show through the gap. Fixed at both rest and
  mid-scroll.

## [0.9.0] - 2026-09-10

- [Feature] **A cross-table**: one row per player, one column per published
  round, showing who they played, which colour, and the result from that
  player's own side of the board. The single thing a visiting arbiter looks
  for first on a results site, and this one did not have it until now.
- [Fix] **A tournament whose arbiter withheld the standings still handed the
  same placings back through every player's own card.** Closed, the same
  way the cross-table already closes it.
- [Change] **OpenResults is now licensed under the Elastic License 2.0**,
  the same terms as OpenPairings, with an explicit permission allowing a
  federation to host it for its own member clubs. The repository had been
  public with no licence at all since the split, which is not a permissive
  default - it is "all rights reserved" - so nobody actually had the right
  to run their own copy.

## [0.8.0] - 2026-09-09

- [Security] **The entry form's rate limit could be exhausted by anyone
  submitting through it**, because every request looked like it came from
  the same address - the tunnel this site runs behind, not the actual
  visitor. It is now keyed by the visitor's own address.
- [Fix] **A tournament's entry queue had no limit on how many entries it
  would hold.** One tournament being flooded can no longer fill up and
  crowd out another's.
- [Security] **The page cache's own validator was predictable enough to
  work out from the outside in seconds.** It is now drawn from a secret this
  server never discloses, so a collision can no longer be produced to
  order.

## [0.7.0] - 2026-09-08

- [Feature] **This site now speaks Dutch and French as well as English**,
  chosen from your browser's own language automatically, with a switch in
  the header that remembers an explicit choice.
- [Feature] **A link to a tournament now names it when pasted into a chat
  app or club WhatsApp group** - a title, a short description and the
  tournament's own dates, instead of a bare URL - honouring whatever the
  arbiter has chosen to keep off the page.
- [Fix] **A board with an empty seat and a real result is now named for
  what it is** - a vacated seat - instead of being shown as an ordinary
  bye, on tournaments published from a version of OpenPairings that sends
  the difference.
- [Fix] **Several display switches an arbiter can turn off (hiding the
  city, the dates, or the standings) had quietly stopped working on the
  front page and the projector view**, even though they still worked
  everywhere else. All of them are now honoured on every page that shows
  the fact they control.
- [Fix] **Publishing one tournament could wipe every OTHER tournament's
  warm page cache.** No visitor was ever shown the wrong page because of
  it, but a busy weekend with several events running at once paid for a
  full re-render on all of them every time any one published. Each
  tournament's cache is now its own.

## [0.6.0] - 2026-09-06

- [Security] **Closed two denial-of-service advisories in this site's HTTP
  client** (the same `mint` advisories OpenPairings closed the same week):
  one could exhaust memory from a malicious response, the other could stall
  on pathological chunked data.
- [Fix] **A bye's label on the pairings table sat two or three columns to
  the left of where an opponent's name would be**, looking like it had
  landed in the wrong row even though the numbers added up. It now sits
  under "Opponent", where a name would be.

## [0.5.0] - 2026-09-04

- [Feature] **A projector view for a round's boards**: reached from a link
  on the round page, it pages through the boards a screenful at a time when
  they don't all fit on one screen, in a high-contrast theme meant for the
  back of a hall, and keeps itself current without ever needing a reload.

## [0.4.0] - 2026-08-31

- [Feature] **Right-click a player's name for a quick answer to "why am I
  in this position"** - rank, score, and each tiebreak's own working, in an
  overlay, without leaving the page you were reading. Left-click still goes
  to that player's full page, which now also carries a chart of their score
  through the tournament.
- [Feature] **When a tiebreak was used to order two players but is not
  itself shown**, the standings now say so, since the order can still
  depend on a number the page never printed.
- [Feature] **The footer now says which exact build is serving the page** -
  the release, the commit and when it was compiled - so a deploy that did
  not actually land is visible on the page instead of invisible.
- [Change] **Standings and player pages stopped re-fetching and re-decoding
  the whole published document from the database every 20 seconds for every
  reader.** An unchanged page now costs a single lookup instead of hundreds
  of kilobytes of JSON, and a round just published renders once and is sent
  to everyone waiting rather than once per reader.

## [0.3.0] - 2026-08-29

- [Feature] **Six colour themes**, chosen in the header and remembered on
  this device - a board green, a cool slate, and a high-contrast theme for
  a projector, alongside the original - and OpenResults' own mark, the same
  silhouette as OpenPairings' own in this site's colour.
- [Feature] **The entry form can search the arbiter's own FIDE list** to
  fill in a player's rating, title and federation, without this site
  keeping a copy of that list itself.
- [Feature] **`mix openresults.backup`** - list, verify and restore a
  complete backup of everything this site holds: every published
  tournament, its whole history, and the entry queue behind it.
- [Fix] **Embedding a tournament's page inside another site never actually
  worked**, silently blocked by a security header nobody had noticed was
  there. It works now: nothing on this site needs a login to protect, so
  there is nothing embedding could steal.
- [Fix] **A bye kept only the player's name, dropping the title and rating
  every other row on the same page shows for them**; a player with no
  rating at all now shows a dash rather than a blank cell, which used to
  read as "not entered yet" instead of "there is none".

## [0.2.0] - 2026-08-29

- [Feature] **A published tournament can now be taken down**, removing
  every trace of it - its whole history and the entry queue's email
  addresses included. Before this the only way was SSH and hand-editing
  the database directly, which meant in practice that a tournament
  published by accident stayed published.
- [Feature] **Each tournament now gets its own key for publishing to it**,
  instead of one key shared by every tournament on the server - so holding
  the key to publish one event no longer means being able to overwrite any
  other.
- [Fix] **This site had quietly stopped honouring two things the arbiter
  had already decided**: whether a tournament is still taking entries, and
  that a hand-set standings order was actually hand-set rather than
  computed from a tiebreak. Both are read from the published document and
  honoured again.

## [0.1.0] - 2026-08-28

- [Feature] **First public release.** A tournament published from
  OpenPairings is stored here and rendered as standings, pairings for each
  round, and a card for every player - read-only, with no accounts and
  nothing to log into.
- [Feature] **A public entry form**, and the endpoint the arbiter's own
  software uses to collect what it collects, rate-limited per address.
