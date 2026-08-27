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

Today those are the same process, which means a chess venue's wifi - school
gyms, hotel basements - can block an arbiter from pairing round 5. It also
means a popular open's standings page is served by the same machine that is
trying to run the tournament.

Splitting them lets the arbiter's side run entirely on a laptop with no
network at all, and lets this side be cached hard and fall over without
stopping anybody's chess.

## What it does

1. **Publish.** Accepts a snapshot of a tournament and serves it: pairings
   per round, standings with the arbiter's chosen tiebreaks, a crosstable.
   A published round is immutable, so it caches for a long time.
2. **Registration.** Takes entries from a public form and holds them in a
   queue. It never writes to a tournament - the arbiter's machine pulls the
   queue, and the arbiter decides who is in.

## What it deliberately does not do

- **It does not calculate.** Standings arrive already computed, tiebreaks
  applied, in the arbiter's chosen order. The arbiter's screen is the
  document of record and this page must never contradict the hall.
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

## Status

Nothing built yet. The schema is the first thing, because it is the only
part that is expensive to get wrong.
