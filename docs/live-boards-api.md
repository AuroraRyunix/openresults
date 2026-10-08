# Live boards: the ingest API

What a hall relay (Alnasl, reading the physical boards) implements to put the
games of a round in front of spectators, move by move. The spectator pages
are `/t/:slug/live`, `/t/:slug/live/:round` and `/t/:slug/live/:round/:board`
(and a live view of the hall display); this document is the one write path
behind them.

The moves and clocks of a game never travel in the snapshot. The snapshot
(`docs/snapshot-schema.md`) says who plays whom on which board, and what the
arbiter has published; this API says what is on the board right now. They are
joined by `(round, board)` when a page is drawn. A game is shown only if its
board is in the published snapshot.

## One request

```
POST /api/tournaments/:slug/live
Authorization: Bearer <relay key, ingest token or installation key>
X-OpenResults-Key: <the tournament's key, if it has been claimed - not for a relay key>
Content-Type: application/json
```

`:slug` is the tournament, which must already have published at least once
(`404 tournament_not_published` otherwise) and must not be hidden.

### Credentials

**A relay key is the credential for a hall relay.** The other two can rewrite
the tournament; a relay is a box in a playing hall that can be lost or stolen.

- a **relay key** (`orrk_...`), made per tournament by an admin in the panel
  (Tournaments, the tournament, Relay keys). It is shown once, when made, and
  the server keeps only a fingerprint; list, last use and revoking are on the
  same page. It authorises **this route for that one tournament and nothing
  else** - not another slug (`403 relay_key_wrong_tournament`), not a publish,
  history, registrations, delete or the admin panel (the anonymous
  `401 unauthorized`, as for any credential the route does not take). A
  revoked key is `403 relay_key_revoked`. It stands in for the tournament key:
  send no `X-OpenResults-Key` with it. Budget: 1200 requests a minute per key,
  `429 rate_limited` with `Retry-After` beyond it; a paused server
  (`publishing_paused`) and a blocked address are refused as for a publish.

The other two credentials are the same as a publish (`docs/public-publishing.md`), checked
by the same plug:

- the operator's ingest token, or
- an installation key (`orik_...`) for an installation that **owns** the slug
  (`403 not_owner` otherwise; `403 installation_suspended` / `installation_revoked`
  as for a publish).

With either of those, and exactly as a publish, **the tournament's own key** in `X-OpenResults-Key`
when the slug has been claimed (`403 key_required` / `403 key_mismatch`). The
relay is one more machine allowed to speak for the tournament; it is not a way
round who may.

A missing or wrong bearer token is the anonymous `401 unauthorized`. Nothing
here is writable without one.

An installation key has its own budget on this route, 1200 requests a minute
per installation (a relay posts a board every few seconds, which the publish
budget would refuse), `429 rate_limited` with `Retry-After` beyond it. A
paused server (`publishing_paused`) and a blocked address are refused as for a
publish.

### Body

```json
{
  "round": 3,
  "board": 12,
  "moves": ["e4", "e5", "Nf3", "Nc6", "Bb5"],
  "white_ms": 4310000,
  "black_ms": 4522000,
  "running": "black",
  "status": "live"
}
```

| field | | meaning |
|---|---|---|
| `round` | required, 1-999 | the round number of the snapshot |
| `board` | required, 1-9999 | the board number **as the snapshot numbers it** (`rounds[].boards[].board`). In a team event, the round-wide number, not the board within the match |
| `moves` | `moves` or `fen` | the game so far: SAN, from the start position or from `start_fen`. The whole list every time (see below). At most 700 plies |
| `fen` | `moves` or `fen` | the current position. With `moves`, a check that they agree; alone, the game is shown without a move list |
| `ply` | with `fen` alone | the number of plies played. With `moves` it must equal their count (`422 ply_mismatch`) |
| `start_fen` | no | the position the moves start from, for a game that does not begin from the standard one. Chess960 castling is not supported |
| `white_ms`, `black_ms` | no | each clock in milliseconds, as it reads **at the moment of this report** |
| `running` | no | `"white"`, `"black"`, or `"none"` / `null` when neither runs. The server counts the running clock down from the time it receives the report |
| `status` | no | `"live"` (default) or `"finished"` |
| `result` | no | the relay's suggestion: `"1-0"`, `"0-1"`, `"1/2-1/2"` or `"*"`. Only meaningful with `status: "finished"` |
| `replace` | no | `true` for a full resend that replaces whatever is held (below) |

A partial update leaves what it does not mention alone: `white_ms` alone
changes only White's clock.

### Moves

`moves` is checked for legality, move by move, from the start position (or
`start_fen`) by the server's own checker. The first illegal move refuses the
**whole** request: `422 invalid_moves` with `ply` set to its 1-based number and
a `detail` saying what is wrong with it. Nothing is stored.

SAN is read leniently where relays differ and are not ambiguous: a missing
`x`, a missing or extra `+` / `#`, `0-0` for `O-O`, `e8Q` for `e8=Q`, an
unneeded disambiguation. A move that fits two legal moves is
`422 invalid_moves` (ambiguous). Stored moves are canonical SAN, so a
spectator's PGN is clean whatever the relay sent.

Send the **whole list on every update**. It is what makes every request
idempotent and every retry safe: the server only replays the plies it has not
seen, and compares the rest by string.

### Idempotent, and tolerant of order

Updates for one board are keyed by `(slug, round, board)` and decided by the
number of plies:

| update's plies | what happens |
|---|---|
| fewer than held | ignored: `200` with `"applied": false, "reason": "older_than_stored"`. A late retry can never undo a newer move |
| equal | applied: clocks, `status` and `result` are refreshed. The moves must agree with the held ones |
| more | applied. The held moves must be a prefix of the new list |

An update whose moves **disagree** with those held (a different move at a ply
already stored) is `409 moves_conflict`. That is deliberate: a correction is a
statement, not a race, so it says so.

`"replace": true` is the full-game resend, for when the relay has re-read the
game from the board and wants it to win: it replaces whatever is held,
whatever the ply. Plies that are still identical keep the time they were first
heard (which matters for the broadcast delay below); the plies from the first
difference are new. A game that was `finished` is reopened only by a higher
ply or by `replace`.

A game that arrives with `status: "finished"` stays finished. `finished_at` is
the time it was first reported finished.

### Reply

```json
{ "status": "ok", "applied": true, "ply": 5 }
```

or, for an update older than what is held,
`{"status": "ok", "applied": false, "ply": 7, "reason": "older_than_stored"}`.

### Several boards in one request

```json
{ "boards": [ { "round": 3, "board": 1, "moves": [...] }, { "round": 3, "board": 2, "moves": [...] } ] }
```

At most 64. The reply is always `200` with one result per board, in order,
because one illegal move must not hide that the others were stored:

```json
{ "status": "ok", "results": [
  { "round": 3, "board": 1, "status": "ok", "applied": true, "ply": 31 },
  { "round": 3, "board": 2, "status": "error", "error": "invalid_moves", "detail": "ply 14: ...", "ply": 14 }
] }
```

### Errors

The same body as every API route (`{"error": "<code>", "detail": "..."}`,
dispatch on `error`).

| status | `error` | meaning |
|---|---|---|
| 401 | `unauthorized` | no or wrong credential |
| 403 | `key_required`, `key_mismatch` | the tournament has been claimed; send its key / it is the wrong one |
| 403 | `not_owner`, `tournament_hidden`, `installation_suspended`, `installation_revoked`, `address_blocked` | as for a publish |
| 404 | `tournament_not_published` | the slug has published nothing (or is hidden) |
| 409 | `moves_conflict` | the moves disagree with those held; send `replace: true` to replace the game |
| 422 | `invalid_request` | a field missing, mistyped or out of range |
| 422 | `invalid_fen` | `fen` or `start_fen` is not a position with one king a side and no pawn on a back rank |
| 422 | `invalid_moves` | a move is illegal or ambiguous; `ply` names it |
| 422 | `ply_mismatch` | `ply` is not the number of `moves` |
| 422 | `fen_mismatch` | `fen` is not where `moves` lead (compared on piece placement and side to move) |
| 429 | `rate_limited` | over the installation's budget; wait `retry_after` seconds |
| 503 | `publishing_paused` | the operator has paused writes |

A relay should treat 4xx other than 429 as "this message is wrong, do not
retry it unchanged", and 429 / 5xx / network errors as "retry the same
message": it is safe, that is the point of the keying.

## What spectators see

- A board with no game reported shows "Not started".
- A game in progress shows the moves, the clocks counting down in the browser
  from the last report, and the last move. A running clock is corrected at
  every report; keep reporting (every few seconds, or on each move and on a
  clock correction) rather than assuming the browser has the time.
- The result printed is the **published** one when the arbiter has one; else,
  once the game is `finished` and the round's results are public
  (`rounds[].results_public` is not `false`), the relay's `result`, marked as
  provisional. A round whose results are withheld shows that the game is over
  and nothing else.
- Names, titles and ratings follow the arbiter's display ticks, exactly as
  on the round page. A tournament whose pairings are switched off
  (`display.pairings: false`) shows no live boards at all.
- A game on a board that is not in the published snapshot is stored and not
  shown, until the arbiter publishes that round.

## The broadcast delay

Organisers may be required to delay what spectators see (FIDE anti-cheating
rules). An administrator sets it per tournament, in minutes, in the admin
panel (Tournaments, the tournament, "Live board delay"). Default 0.

The ingest always stores real time: each ply records when it was first heard,
and the clocks reported with it. Every page, the hall display and the PGN
download then show the game **as it stood that many minutes ago**: the plies
heard by then, the clocks as they were with them, the result no sooner than
that after the relay reported it. Nothing past the cutoff is sent to a
browser. Changing the delay takes effect at once, both ways; nothing is
rewritten.

Report moves **with their clocks in the same request**: with a delay, the
clocks shown come from the newest visible ply that carried any. A game
reported by FIDE only (no `moves`) cannot be delayed ply by ply; it appears
once its latest position is older than the delay.

## Developing against it

`mix openresults.live_sim --slug <slug> --token <ingest token>` replays PGN
files (three public-domain games ship in `priv/live_sim`) into this API at a
configurable speed, with clocks. See the task's `--help` text in
`mix help openresults.live_sim`. It posts exactly what is described here, so
a relay that behaves like it behaves.

## What the snapshot may add

Two optional keys, both additive and read as absent when missing:

- `tournament.live_boards: true` - the arbiter says this tournament has live
  boards. The static pages then link to `/t/:slug/live`. They link on this
  word and on nothing the relay has done, because those pages are cached per
  snapshot (a link that appeared with the first move would be stale until the
  next publish). The live pages work with or without it.
- `tournament.hall.live: false` - leaves the live boards out of the hall
  display's cycle. The view is otherwise on, and has no pages (so is skipped)
  until a game is in progress.
