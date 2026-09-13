# The Belgian (KBSB/FRBE) roster relay

Agreed alongside `docs/public-publishing.md`, 2026-09-13. A desktop
OpenPairings install has no safe place to hold the KBSB data platform's API
key (see `KBSB_API_URL`/`KBSB_API_KEY` on the hosted OpenPairings server,
and `PairingsEngine.Federations.BEL.Api`'s moduledoc for why that key can
never ship inside a desktop release). This server relays a **reduced** copy
of the same roster instead, over the credential a desktop install already
holds - its installation key, or an operator token if one is configured.

## Source

The KBSB data platform (`kbsb-dataplatform`), the same
`GET /api/v1/players_national/export` the hosted OpenPairings server reads
directly. This relay is a second, independent client of that API: it holds
its own copy of the key
(`OPENRESULTS_KBSB_API_URL`/`OPENRESULTS_KBSB_API_KEY`), separate from
`KBSB_API_URL`/`KBSB_API_KEY` on the OpenPairings side, so revoking one
never requires touching the other.

Both env vars unset (the default) turns the whole feature off:
`OpenResults.Federations.BEL.Config.enabled?/0` is false, the sync never
runs, and the endpoint answers 404 `not_configured` - not an empty list,
which would look like a relay that ran and found nothing rather than one
that was never turned on.

## Data protection: only what KBSB already prints publicly

**The allowlist is hand-written**, in exactly one place:
`OpenResults.Federations.BEL.Fields.allowed/0`. Every row the upstream
export returns is reduced through `Fields.reduce/1` immediately, before it
is stored or ever leaves this process's memory:

    national_id, last_name, first_name, national_rating,
    fide_id, club_number, club_name, federation

These are the fields KBSB already shows on its own public rating lists.
**Never** a birth date or year, an email address, a postal address or a
phone number, whatever the upstream export happens to carry - and never
the internal `died`/`affiliated` flags the OpenPairings-side sync keeps for
its own lookups, which answer a question this relay was not asked and are
not printed on a public list. Checked against
`PairingsEngine.Federations.BEL.Member` and `.Parser` - the only two things
that read a synced row on the OpenPairings side - so there is deliberately
nothing here they do not use, and nothing they use that is missing here.
`test/openresults/federations/bel/fields_test.exs` proves extra fields
(including a fake `email`/`address`/`phone`) are dropped.

**Before this goes live on a shared server, the operator must confirm with
KBSB that relaying its export through OpenResults this way is permitted.**
This document does not settle that question - it only says what leaves this
server if the answer is yes.

## Sync

`OpenResults.Federations.BEL.Scheduler` runs
`OpenResults.Federations.BEL.Sync.run/0` once a day, plus once at boot
(after a short delay) if the stored copy is missing or more than a day old
- the same shape as `OpenResults.Retention.Scheduler` and
`OpenResults.Backup.Scheduler`. `Sync.run/0` is a no-op when the feature is
not configured.

`OpenResults.Federations.BEL.Api` walks the export the same
cursor-paginated way `PairingsEngine.Federations.BEL.Api` does against the
same endpoint, reducing every row through `Fields.reduce/1` as it is read.
A page that fails (a dropped connection, a timeout, a 5xx) is retried a few
times with a growing pause before the run gives up for the day; the next
scheduled run, or the boot check, tries again.

## Storage: never a half-written sync

`OpenResults.Federations.BEL.Store` writes the reduced roster to a temp
file and renames it over the real one - atomic on the filesystems this app
ships on - and only swaps in the in-memory copy the endpoint actually
serves from (an ETS table, so a request never touches disk) after that
rename succeeds. A request during a sync sees the old roster or the new
one, never a partial one. A failed sync (`Store.put_error/1`) leaves the
previously-served roster untouched and is visible only in the admin panel.

## `GET /api/federations/bel/players`

Behind the same `:ingest` pipeline as history and registrations
(`OpenResultsWeb.Plugs.IngestAuth`): an installation key or the operator
token, `InstallationAccess`'s `:bel_players` action (refused while
suspended or revoked, like history - it is not tied to any tournament, so
there is no ownership check). Rate-limited in the controller itself,
reusing `OpenResults.RateLimit`'s fixed-window counter, keyed on the
credential. Gzipped when the client accepts it; a strong ETag with a 304 on
a matching `If-None-Match`.

```json
{
  "updated_at": "2026-09-13T10:00:00Z",
  "count": 2,
  "players": [
    {
      "national_id": "12345",
      "last_name": "Peeters",
      "first_name": "An",
      "national_rating": null,
      "fide_id": 2500123,
      "club_number": 130,
      "club_name": "KGSRL",
      "federation": "BEL"
    },
    {
      "national_id": "67890",
      "last_name": "Janssens",
      "first_name": "Tom",
      "national_rating": null,
      "fide_id": null,
      "club_number": null,
      "club_name": "",
      "federation": "BEL"
    }
  ]
}
```

`national_rating` is `null` for every row: the KBSB national ELO system was
retired and archived in July 2026 (see
`PairingsEngine.Federations.BEL`'s docs/kbsb-sync.md), and the upstream
export carries no rating at all. The field is kept for schema stability -
should KBSB ever publish a rating again, only `Fields.reduce/1` needs a
change.

## Admin panel

`/admin/settings` shows, read-only: whether the relay is configured, the
last successful sync's time and player count, and the last error, if any
(`OpenResults.Federations.BEL.admin_stats/0`). Nothing personal is written
to the action log by any of this - there is no admin action here to log,
only a background job.

## OpenPairings side

`PairingsEngine.Federations.BEL` adds "via the results site" as a second
source, used when `KBSB_API_URL`/`KEY` are unset and the app has a working
OpenResults connection - see that repository's docs/kbsb-sync.md.
Precedence: the direct data-platform key first (hosted), then the results
site, then the manual file upload.
