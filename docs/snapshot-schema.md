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
    "fide_rated": true,
    "registration_open": true
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
    "manual_order": false,
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
        "working": {
          "BH": {
            "total": 22.5,
            "parts": [
              { "round": 1, "opponent": 12, "value": 4.0 },
              { "round": 2, "value": 2.5, "kind": "virtual" },
              { "round": 3, "opponent": 7, "value": 3.5, "kind": "cut" }
            ]
          }
        },
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

**`tournament.registration_open`** - whether the arbiter is accepting entries
through this site's form. Added 2026-08-29. **Absent means open.**

That default is load-bearing rather than merely tolerant. The arbiter's app
enforced this flag itself until it stopped serving its own entry form; every
snapshot published before then is silent, and this server accepted entries
for all of them. Reading silence as "closed" would have shut every
already-published form the moment the field shipped, with nothing in either
app to explain why. The failure directions are not symmetric either: an entry
that should not have been taken lands in a queue an arbiter reads and
rejects, while a form that is shut when it should be open turns a real person
away and tells nobody.

**`standings.tiebreaks`** - declared once, ordered, with a human label.
`rows[].tiebreaks` is positional against it. This is what lets the renderer
stay dumb: it does not know what BH means, how many there are, or what order
the arbiter chose.

**`standings.rows[].working`** - how each tie-break number was reached, keyed
by code. Added 2026-08-30. Absent, or `{}`, means no working was published.

Each entry is a `total` and a list of `parts`, one per round, and the parts
sum to the total. A part carries:

| field | meaning |
| --- | --- |
| `round` | the round it came from - the join key against `rounds[]` and a player's card |
| `opponent` | the opponent's `no`, **absent** when there is nobody to name |
| `value` | what it contributed |
| `kind` | `played` (**absent** means this), `virtual`, `cut` or `excluded` |

`virtual` is FIDE Article 16's notional opponent for a round the player did
not play. `cut` is a real contribution that a cut modifier discarded, and
`excluded` is one the tie-break's own rule did not count - a Koya opponent
below the threshold. **Both are sent and both must be left out of the sum**;
they are here so a reader can see what did not count and why, which is the
half a bare number never showed.

`opponent` and `kind` are omitted at their commonest values rather than sent
as `null` and `"played"`. There are as many parts as players x codes x
rounds, so those two keys cost more than the rest of the document put
together on a large event. Absent-means-the-default is how `listed` and
`manual_order` already read.

**Only the tie-breaks that cannot be re-derived here are sent.** The Buchholz
family, Sonneborn-Berger, Koya and average rating - everything built on an
opponent's Article 16 **adjusted** score, which is not in this document and
cannot be, because it depends on that opponent's own unplayed rounds. Wins,
games with Black and the running score are visible in the results already, so
they are not sent. Direct Encounter is never sent: it is a mini-match among
players tied on everything else, not a per-round sum.

That restriction is the reason this travels at all rather than being computed
here. Adding up the opponents' finishing scores on this side would look
right and be wrong: it would print a total that disagrees with the number
beside it, in front of the players. See the app's first rule, above - the
arbiter is the authority.

Sending it costs roughly 3.4x the payload on a 300-player, 11-round event
(173 KB to 583 KB, measured), and every changed version is kept, so the
growth compounds across a tournament's publishes. Well inside the body limit,
but worth knowing before adding more.

**Withheld with the tie-break columns.** An arbiter who turns off
`display.tiebreaks` is hiding the arithmetic, and this is more of it than the
columns ever showed, so it is not sent at all rather than sent and hidden -
the same rule as a withheld round or board.

**`standings.manual_order`** - whether the arbiter set `rows[].rank` by hand
instead of computing it from the tiebreaks. Added 2026-08-29. Absent means
no.

It changes nothing about how the rows are read: they are rendered in the sent
order regardless, because that order is the arbiter's answer either way. It
exists so the page can say which kind of answer it is. Until this field
existed the disclosure lived only on the arbiter app's own public standings
page, which was removed - so the ordering would have travelled while the fact
that a person chose it did not.

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

## The tournament key, and taking a tournament down

Not part of the document. It travels in a **header**, and the reason is worth
stating because the alternative looks tidier: the snapshot is stored whole and
verbatim, and `GET /api/tournaments/:slug` serves that stored document to the
public. A credential inside the payload would therefore be written to disk in
plaintext and then published on a web page. The document describes a
tournament; a secret is a fact about the transport, and it belongs beside the
bearer token.

```
POST /api/snapshots
Authorization: Bearer <the server's ingest token>
X-OpenResults-Key: <a random key this machine generated for this tournament>
```

Two questions, deliberately separated:

| header | answers |
|---|---|
| `Authorization` | may this machine talk to this server at all |
| `X-OpenResults-Key` | may it touch THIS tournament |

The names invite one specific mistake, so it is worth saying once: **both
headers carry an OpenResults secret and they are not the same secret.**
`Authorization` holds the server-wide ingest token that an operator put in
`openresults.service`; `X-OpenResults-Key` holds a per-tournament key the
arbiter's machine generated and only that machine has. When a publish is
being debugged, establish which of the two is wrong before anything else.

**The client generates the key**, once per tournament, at random, and keeps
it. This server stores only a SHA-256 digest of it and can never show it back.

**Trust on first use.** The first publish of a slug that carries a key claims
it; every later publish of that slug, and any delete, must present the same
key. It is TOFU, and that is acceptable here because nothing reaches this
check without the server-wide ingest token - so the exposure it closes is
*accident*, two machines picking the same obvious slug, rather than attack.

**A publish with no key is accepted for a slug nobody has claimed.** This is
the additive-only rule applied to authentication. Snapshots already exist from
before any of this, so slugs exist with a season of history and no key, and
laptops in the field will not send one until their arbiters update. Refusing
them would take live tournaments off the air mid-event.

So there is no backfill and no admin step: **a legacy slug is adopted by the
first publish that carries a key.** Once claimed, a keyless publish to that
slug is refused - otherwise an old client could take over a claimed tournament
by simply omitting the header, and the whole thing would be decorative.

| slug | request | result |
|---|---|---|
| unclaimed | no key | published, stays unclaimed |
| unclaimed | a key | published, **claims the slug** |
| claimed | the same key | published |
| claimed | a different key | `403 key_mismatch`, nothing changes |
| claimed | no key | `403 key_required`, nothing changes |

**403, not 401.** A 401 comes from the pipeline and means "you may not talk to
this server". A 403 means "you may, but not to this tournament". An arbiter
whose round will not publish needs to know which secret to go and check.

### Taking a tournament down

```
DELETE /api/tournaments/:slug
Authorization: Bearer <ingest token>
X-OpenResults-Key: <the tournament's key>
```

Removes **everything** this server holds for the slug: every snapshot
including the whole history, the registration queue with its email addresses,
and the key claim itself.

Every snapshot, not the current one, and that distinction is the whole route.
The table is append-only and `/history` serves earlier rows by `?at=`, so
deleting only the current snapshot would empty every public page - and leave
the entire event, names and ratings and federations and any round since
retracted, one query away for anyone holding the ingest token. It would look
like it worked.

The key claim goes too, so the slug returns to unclaimed and can be published
again with a fresh key. Answers `200` with counts even when nothing was there,
because a delete is idempotent and a retry after a timeout is not an error:

```json
{
  "status": "deleted",
  "slug": "gent-spring-open-2026",
  "deleted": { "snapshots": 11, "registrations": 3, "key": 1 }
}
```

An **unclaimed** slug can be deleted by any holder of the ingest token. That
is deliberate: it is the same authority that could already overwrite the
tournament into an empty one, and refusing would mean a tournament published
before keys existed could never be taken down at all - which is the hole this
route exists to close, left open for exactly the tournaments that have been
public longest.

### Break-glass

A key lives on one laptop, and laptops die. A request may present the
**server-wide ingest token** in `X-OpenResults-Key`, and the key check is
overridden. Every use is logged at warning level with the slug and the action.

It never claims a slug: storing the master secret as a tournament key would
mean rotating the ingest token locked out every tournament claimed that way.

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
