# OpenResults

The public half of [OpenPairings](https://github.com/AuroraRyunix/openpairings):
published pairings, standings and player registration for a chess tournament.

It renders what an arbiter sends it. **It computes nothing.**

## Why it is a separate thing

An arbiter's tool and a spectator's page want opposite things.

| | the arbiter | the public |
|---|---|---|
| writers | exactly one person | none |
| readers | one | hundreds, in bursts |
| latency | instant, and offline-tolerant | seconds are fine |
| when it matters | during the round | after it |
| cost of failure | the round cannot be paired | somebody refreshes |

They used to be one process, which meant a chess venue's wifi - school gyms,
hotel basements - could block an arbiter from pairing round 5, and a popular
open's standings page was served by the same machine trying to run the
tournament.

Splitting them lets the arbiter's side run entirely on a laptop with no
network at all, and lets this side be cached hard and fall over without
stopping anybody's chess.

## What it does

1. **Publish.** Accepts a snapshot of a tournament and serves it: standings
   with the arbiter's chosen tiebreaks, a page per round, and a card per
   player showing every game they have played. A published round is
   immutable, so it caches for a long time.
2. **Registration.** Takes entries from a public form and holds them in a
   queue. It never writes to a tournament - the arbiter's machine pulls the
   queue, and the arbiter decides who is in.

The arbiter chooses how much of it is shown. Ratings, titles, federations,
clubs, categories, tiebreak columns and the player cards can each be switched
off per tournament, and a tournament can be published without appearing on the
front page at all. See
[OpenPairings' public-pages doc](https://github.com/AuroraRyunix/openpairings/blob/main/docs/public-pages.md).

## What it deliberately does not do

- **It does not calculate.** Standings arrive already computed, tiebreaks
  applied, in the arbiter's chosen order - hand-set, if that is what they
  did, and the page says so. The arbiter's screen is the document of record
  and this page must never contradict the hall.
- **It does not hold tournament state.** It has snapshots and a registration
  queue. The source of truth is the arbiter's machine.
- **It does not know who anybody is.** No accounts, no sessions, no cookies
  on the reading path.
- **It cannot leak what it was not sent.** An unpublished round and a hidden
  board are absent from the payload, not filtered on render.

## The contract

One document, described in
[`docs/snapshot-schema.md`](docs/snapshot-schema.md). It is deliberately
boring and deliberately hard to change: a laptop running an old OpenPairings
will be publishing to a new server for months, the same way SwissManager has
always worked. Additive only, never rename, the reader ignores what it does
not recognise.

The rule that makes that work is that **an absent field always means what the
server did before the field existed**. A payload with no `registration_open`
is taking entries, because that is what every payload published before that
field was added meant. A payload with no `display` map shows everything. Read
either the other way and a change here would silently alter tournaments
nobody touched.

## The JavaScript

There is no bundle, no socket and no request on load. Two inline scripts,
both of which only ever act after the page is already readable:

- a theme preference reader that runs before first paint;
- a right-click player card, a 20-second refresher for the standings, and the
  FIDE search on the entry form.

Every page renders completely with all of it switched off. A player's name is
a real link to a real page; the refresher swaps one region rather than
reloading; the theme falls back to light. That is the condition under which
adding any of it was worth it - hundreds of phones load this over a playing
hall's wifi, and a result should be readable the moment the HTML lands.

## Embedding

Every page may be put in an iframe, so a club can show its own tournament's
standings on its front page. Safe because there is nothing here to clickjack:
no session, no login, and the two things that write take no authority from
the visitor either.

`PUBLIC_FRAME_ANCESTORS` restricts it to an origin list, or `'none'` to switch
it off.

## Running it

```
mix setup
mix phx.server
```

### Configuration

| variable | what it does |
|---|---|
| `OPENRESULTS_INGEST_TOKEN` | the shared secret an arbiter's machine publishes with. Unset, every publish is refused. |
| `PUBLIC_FRAME_ANCESTORS` | who may embed these pages. Default `*`. |
| `FIDE_LOOKUP_ENDPOINT` | an arbiter's app this server can reach, so the entry form can offer a FIDE search. Unset, the form asks people to type their own details. |
| `FIDE_LOOKUP_TOKEN` | the token for the above - the same ingest token, travelling the other way. |

The FIDE search needs the two machines to be reachable from each other, which
in practice means deployed together; the list itself stays on the arbiter's
machine, because that is the copy they actually pair from.

## Status

In production. Publishing, registration, tournament keys, takedown, themes,
per-tournament display rules and the FIDE search are all live and covered by
the test suite.
