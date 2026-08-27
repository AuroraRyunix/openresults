# The snapshot schema

The one contract between OpenPairings and OpenResults. An arbiter's machine
builds a snapshot and pushes it; this app stores it and renders it. Nothing
else crosses.

This file is the specification. Change it reluctantly.

## Why it looks like this

**It describes a tournament, not a database.** TRF16 has survived twenty
years because it describes chess rather than software; a payload shaped like
OpenPairings' Ecto schema would need a new version every time a column moved.
So: rounds, boards, standings - things an arbiter would recognise.

**Old clients must keep working.** A laptop running OpenPairings 0.17 will be
publishing to a server running 0.25 for months, because arbiters update when
they feel like it and that is how SwissManager has always worked. Therefore:

- **Additive only.** A field is never removed, never renamed, and never
  repurposed. If it stops being meaningful it becomes optional and is
  ignored.
- **The reader ignores what it does not recognise.** A newer client sending
  a field this server has never heard of must not be an error.
- **The envelope is versioned, not the fields.** `version` changes only for
  a break that cannot be expressed additively, which should be never.

**No database ids cross the boundary.** Players are referenced by their
tournament pairing number (`no`), which is the TRF start number - stable
within the event, meaningful to an arbiter, and useless to anyone trying to
correlate players across tournaments.

**The arbiter is the authority.** Standings arrive computed, with tiebreaks
already applied. This app never calculates a placing. That is deliberate:
the arbiter's screen and the public page must agree, and the printed
crosstable is the document of record. A server that recomputed could
silently disagree with the hall.

**Withholding is enforced at build time.** A round the arbiter has not
published, and a board they have hidden, are simply *absent from the
payload*. The server cannot leak what it was never sent - which is a
stronger guarantee than the current design, where a public page has to
remember to filter.

## The document

One JSON document per publish. It carries the whole tournament as known at
that moment, not a delta - a tournament is a few hundred kilobytes at worst,
deltas would need ordering guarantees over an unreliable network, and a
whole document is trivially idempotent.

```json
{
  "schema": "openresults/snapshot",
  "version": 1,
  "published_at": "2026-08-27T18:00:00Z",
  "source": { "app": "openpairings", "version": "0.17.1" },

  "tournament": {
    "slug": "gent-spring-open-2026",
    "name": "Gent Spring Open 2026",
    "city": "Ghent",
    "federation": "BEL",
    "start_date": "2026-03-01",
    "end_date": "2026-03-05",
    "rounds_count": 9,
    "system": "swiss",
    "arbiter": "Jorian Burssens",
    "fide_rated": true
  },

  "players": [
    {
      "no": 1,
      "name": "Carlsen, Magnus",
      "title": "GM",
      "rating": 2823,
      "federation": "NOR",
      "fide_id": 1503014,
      "club": "Offerspill",
      "category": "A"
    }
  ],

  "rounds": [
    {
      "number": 1,
      "date": "2026-03-01",
      "boards": [
        { "board": 1, "white": 1, "black": 12, "result": "1-0" },
        { "board": 2, "white": 13, "black": 2, "result": null }
      ],
      "byes": [
        { "player": 40, "kind": "pairing-allocated", "points": 1.0 }
      ]
    }
  ],

  "standings": {
    "after_round": 5,
    "tiebreaks": [
      { "code": "BH", "label": "Buchholz" },
      { "code": "SB", "label": "Sonneborn-Berger" }
    ],
    "rows": [
      {
        "rank": 1,
        "player": 1,
        "points": 4.5,
        "tiebreaks": [22.5, 18.25],
        "category": "A"
      }
    ]
  }
}
```

## Field notes, where the choice was not obvious

**`players[].no`** - the tournament pairing number. Every other reference in
the document (`boards[].white`, `byes[].player`, `standings.rows[].player`)
is one of these. Nothing else identifies a player.

**`players[].fide_id`, `rating`, `federation`, `club`, `title`** - all
optional, all frequently absent in club play. A missing key and a `null` mean
the same thing: not known.

**`rounds[]`** - contains only PUBLISHED rounds. An unpublished round is
absent entirely, not present-and-flagged. Same for a hidden board: absent
from `boards`.

**`boards[].result`** - the token OpenPairings already stores, verbatim, with
`null` for a game not yet reported. Taken from the app's own vocabulary rather
than invented here, because a contract that renames things is a contract that
drifts:

| token | meaning |
|---|---|
| `1-0`, `0-1`, `1/2-1/2` | the ordinary three |
| `1-0U`, `0-1U`, `1/2-1/2U` | played but UNRATED - the game happened, it does not count for rating |
| `1/2-0`, `0-1/2` | the VCL.13 asymmetric results |
| `0-0` | played, both score nothing |
| `1-0FF`, `0-1FF`, `0-0FF` | forfeits - unplayed under FIDE Art. 16 |

Carried unflattened because an arbiter reading the page needs to see that a
game was not played, and a spectator needs to understand why a 1-0 did not
move a rating. The renderer may present them however it likes; the token is
what travels.

Two legacy spellings, `+--` and `--+`, exist in historical and SWAR-imported
data for the single-sided forfeits. **The publish path normalises them to
`1-0FF` and `0-1FF`** rather than pushing both spellings across, so this
server only ever sees one vocabulary.

**`byes[].kind`** - `"pairing-allocated"`, `"half-point"`, `"zero-point"`,
`"full-point"`, `"absent"`. The kind and its point value are both carried
because the value is configurable and the kind is what an arbiter recognises.

**`standings.tiebreaks`** - declared once, ordered, with a human label.
`rows[].tiebreaks` is positional against it. This is what lets the renderer
stay dumb: it does not know what BH means, how many there are, or what order
the arbiter chose.

**`standings.after_round`** - which round the placings reflect. Not
necessarily the highest published round: an arbiter may publish pairings for
round 6 while standings still stand after 5.

**`system`** - `"swiss"`, `"roundrobin"` or `"keizer"`. Keizer standings
carry different columns (value, Keizer points, score), so the renderer keys
off this. The alternative - a generic column list - was considered and
rejected as harder to read for the two extra cases it buys.

## What is deliberately NOT in here

**Anything a spectator has no business seeing.** No email addresses, no
phone numbers, no birth dates, no national ID numbers. The publish path
strips these; they exist in the arbiter's database and stay there. A
birth *year* would be defensible for age categories and is not included until
something needs it - which is the additive-only rule working as intended.

**Pairing rationale.** The engine's explanation of *why* a round was paired
that way is an arbiter's diagnostic, and it references internal player ids
that mean nothing here.

**Anything that would let the server recompute.** No individual game points,
no float history, no colour history. If the server had those it would be
tempting to calculate a placing, and then the hall and the web page could
disagree.

## Registration, the other direction

The only payload that travels the other way. The server accepts these from
the public form and holds them; the arbiter's machine pulls, and the arbiter
decides. The server never writes to a tournament.

```json
{
  "schema": "openresults/registration",
  "version": 1,
  "received_at": "2026-02-01T09:12:00Z",
  "tournament_slug": "gent-spring-open-2026",
  "player": {
    "name": "De Vos, Ilse",
    "rating": 1804,
    "federation": "BEL",
    "fide_id": 2503014,
    "club": "KGSRL",
    "email": "...",
    "requested_byes": [3, 4]
  }
}
```

`email` is the one piece of personal data the server holds, because the
arbiter needs to reach the player. It is not part of any snapshot and is
never rendered.
