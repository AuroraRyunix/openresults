# Restore drill, 2026-09-13

The 2026-09-05 audit said, in so many words, "no load test, no live probing,
no restore drill". Both apps had backups; nobody had ever shown that restoring
one gives back a working system. This is the first drill, run for OpenResults
and OpenPairings together, because the property that justifies the backups -
an arbiter can always withdraw what they published - lives across both.
OpenPairings' own write-up is its `docs/restore-drill-2026-09-13.md`.

**Verdict for OpenResults: yes, a restore gives back a working system - if
the operator does three things the documentation did not say** (move the WAL
with the database, migrate, reconcile moderation). Followed literally, the
old instructions produced, depending on how the service had stopped, a site
serving the pre-restore data, or a site answering 500 on every page. Even done
right, a restore silently re-enables revoked installations, reopens closed
registration, lifts address blocks and puts withdrawn tournaments back online.
The code bugs the drill found are fixed; the procedure is rewritten in
`docs/deployment.md` ("Backups", "Restoring a backup", "What a restore
undoes") and was re-run from that text.

## How it was run

Local only, on a Windows 11 workstation (16 threads). No SSH, no deploy, no
connection to either production host.

- **Code**: this repo at `65fb180` (branch `restore-drill`), OpenPairings at
  `6a11122`. Both `main`s moved during the drill - here, the admin pages and
  `transfer_all`; nothing that touches backups.
- **Mode**: `MIX_ENV=prod`, `PHX_SERVER=true`, `mix phx.server` semantics, as
  `openresults.service` runs it, on a scratch database. One difference: the
  listener was pinned to 127.0.0.1 (`config/runtime.exs` binds every interface
  in prod and relies on firewalld; on a workstation that is a LAN exposure and
  a firewall prompt). The nodes ran with loopback-only distribution so the
  drill could drive them; `systemctl stop` was reproduced by `init:stop/0`,
  which is what SIGTERM does to a BEAM, and a crash by killing the process.
- **Instance**: built through the app's own paths. OpenPairings published two
  events over the operator token (with history: every result republished); the
  entry form took three registrations over HTTP; three installations
  registered over `POST /api/installations` from three addresses (via
  `cf-connecting-ip`, as the tunnel delivers it), minted four slugs and
  published three of them; one tournament was hidden; two reports came in
  through the report form; the operator (through `OpenResults.Moderation`)
  opened registration, suspended an installation, blocked a /24 and resolved a
  report. Retention ran after the rows were given realistic ages.
  At backup time: 9 snapshots, 3 registrations, 5 key claims, 3 installations,
  6 tournament rows, 2 reports, 1 block, 1 setting, 6 action log rows.
- **Backups** were taken by the scheduler: its five-minutes-after-boot run
  fired on time, and the reference backup was `Backup.Scheduler.run_now/0`
  (the same GenServer call the 24-hour timer makes). The live database was
  fingerprinted table by table immediately before and after; nothing changed
  in between, so the backup's content is known exactly.
- **Then** the operator kept working: an installation revoked, registration
  closed, publishing paused, a second address block, a pending tournament
  deleted for personal data; an arbiter withdrew one tournament and published
  two new ones; an entry and a report arrived. Then the database file was
  deleted, and the restore began.

## Timings

Local; `mix` on the 2-vCPU VPS starts slower, so read these as proportions.

| Step | As documented before | As documented now |
| --- | --- | --- |
| `--list` | 2.3 s | 2.3 s |
| `--verify` | 2.2 s | 2.3 s |
| `--restore` | 2.2 s | 2.2 s |
| stop | ~1-2 s graceful; the drill's second run was a kill | (killed) |
| swap | 1 of 2 `mv`s failed - the live file was gone | 0.5 s, sidecars included |
| reconcile report | - | 0.3 s |
| `mix ecto.migrate` | - | 2.3 s |
| start to listening | ~2.5 s, then 3 `database is locked` errors | 2.5 s, no errors |
| **total, mechanical** | **about 11 s** | **about 11 s** |

The time that matters at 3am is not in the table: before this drill there was
no restore section in `docs/` at all. The procedure existed only as the four
commands `--restore` printed and a CHANGELOG entry, and three of the steps it
needed were not written anywhere.

## Findings, worst first

### 1. The documented swap could restore nothing and say nothing - FIXED (docs, task output)

`--restore` printed `mv live live.before-restore; mv restored live`. That moves
the database without its `-wal` and `-shm`. After a clean stop those do not
exist. After a crash, an OOM kill or a stop that hits systemd's timeout, they
do - and a restore is exactly when a service is most likely to have died
rather than stopped. Reproduced by killing the drill's instance after twenty
writes, with SQLite itself as the judge:

| What SQLite was given | action log rows | of them, written just before the kill | tournaments | `integrity_check` |
| --- | --- | --- | --- | --- |
| the restored file alone | 6 | 0 | 6 | ok |
| **the restored file + the `-wal`/`-shm` the `mv` left behind** | **27** | **20** | **6** | **ok** |
| the old file with its WAL | 27 | 20 | 7 | ok |
| the old file as the `mv` moved it, without its WAL | 7 | 0 | 7 | ok |

Row two is a database that never existed: the action log's pages come from the
old database through its WAL, the tournaments from the backup. SQLite pairs a
database with whatever `-wal` carries its name and has no way to tell it
belongs to another file; nothing errors, the integrity check passes, and the
next checkpoint writes the mixture into the restored file for good. Row four is
the `before-restore` copy the output said to keep "until you are sure",
missing the last writes. On the OpenPairings side, where `mix ecto.migrate` on
a fresh database leaves a 4 KB file and a 1.5 MB WAL, the same `mv` made the
restored app see the old database entirely and left a `before-restore` copy
with no tables at all.

Fixed: the task now prints a swap that renames all three files together
(`openresults.db.before-restore-<stamp>`, `...-wal`, `...-shm`, which still open
as one database) and the guide explains it. Re-run after killing the node
mid-write: the twenty rows that existed only in the old WAL were in the
`before-restore` copy and not in the restored database.

### 2. A restore undoes moderation and resurrects withdrawn tournaments - RECOMMENDED (policy); procedure documented

Restoring the reference backup after the operator's later work, measured on
the restored, running site:

| After the backup | After the restore (measured) |
| --- | --- |
| installation `in_XWtJ...` revoked | `POST /api/tournaments` with its key: **201**, slug minted |
| `registration_open` closed | `POST /api/installations`: **201**, key issued |
| `192.0.2.0/24` blocked | that registration came from 192.0.2.77 |
| publishing paused | unpaused |
| pending tournament deleted "for personal data" | back, reachable, 2 snapshots |
| **arbiter withdrew `aRXR...` from OpenPairings** | **200, entry form open, 3 registrations with email addresses** - and OpenPairings, having withdrawn it, had already cleared its key: its Take down answered "nothing has been published from this machine". Removed only with break-glass. |
| two tournaments first published | gone; one came back when its arbiter's machine republished (TOFU on the unclaimed slug) |
| a report, an entry | lost |

The action log is restored to the same instant, so it cannot say what to
re-apply, and the arbiter's withdrawal was never in it: `Takedown.purge/1` logs
nothing for an owner's delete, and request lines are at `debug`, so the journal
has nothing either. The only record of what a restore undid is the database it
replaced - if it still opens.

Documented: "What a restore undoes" and a read-only reconcile script that
diffs the restored and `before-restore` databases. In the drill it listed,
exactly, both tournaments back online, both gone, the revoked installation,
both switches, the block and the five later actions.

Recommended, and a decision for the operator rather than a fix:

- Log an owner's `DELETE /api/tournaments/:slug` to the moderation action log
  (actor: the installation or `operator`), so a withdrawal is on record here
  and not only on a laptop.
- Consider a small append-only journal of authority changes - revocations,
  blocks, withdrawals, switch flips - written outside the database (or shipped
  off-box), that a restore can replay. Without one, restoring a backup is
  always a moderation rollback.
- `mix openresults.backup --restore` could run the reconcile report itself
  when the live database is readable, before the swap.

### 3. A backup older than the code boots and fails every page - FIXED (docs)

`mix phx.server` does not migrate (`Ecto.Migrator` is skipped unless
`RELEASE_NAME` is set, and the unit is not a release). A backup taken before
2026-09-12, restored by the old instructions: the app booted and answered
`/changelog`; `/`, every tournament page, `GET /api/server` and publishing
answered **500**, `no such table: tournaments`. With `mix ecto.migrate` between
swap and start: every page 200, the backfill listed the old tournament, a
publish was accepted, no errors. The guide now has the step; the task prints
it.

### 4. `verify/1` passed databases with damaged tables - FIXED

It checked three tables exist and counted `snapshots`. A backup whose envelope
is perfect (valid gzip, valid CRC) around a database with a damaged
`installations` or `tournament_keys` page verified, restored, and failed
`PRAGMA integrity_check` - which is what a backup of a database with a bad
page is. Every damaged envelope the drill made (truncated, tail cut, a flipped
bit, a zeroed block, a damaged header, no header, garbage inside) was already
refused before anything was written; only the damaged database got through.
`verify/1` now runs `PRAGMA integrity_check` and refuses with the first
problems SQLite reports. SQLite's error text also came back as
`<<109, 97, 108, ...>>`; it is now words.

### 5. The PBKDF2 count from the unauthenticated header was trusted - FIXED

OpenPairings bounded this in its 2026-09-01 sweep (L5); this copy of the format
never learned it. An encrypted backup whose header says 20 million iterations
took 7.6 s to refuse; the header will say 5 billion, and `--verify` then runs
for hours with no cancel. A count of 1 was used too. Now the same
10,000-2,000,000 bound as OpenPairings, refused before any key is derived.

### 6. `verify/1` left a decrypted copy of the database in the temp directory - FIXED

On Windows every successful verify left its staging copy behind: the
connection was closed with its prepared statements still alive, SQLite defers
such a close, and the file stays open until the garbage collector finalises
the statements. On every system, a refusal after the file opened never closed
the connection at all. Measured: 5 verifies, 5 copies left; on this workstation
801 `orbak-verify-*.db` files (35 MB) had piled up since 2026-09-12, from test
runs. For an encrypted backup those copies are the plaintext. Statements are
now released and the connection closed on every path; 0 left, accepted or
refused.

### 7. `BACKUP_RETENTION` of 0 or less deleted the newest backups - FIXED

`prune/1` is `Enum.drop(list, keep)`. With 0 that deletes every backup,
including the one the scheduler has just written; with -2 it dropped from the
other end and kept the **two oldest**, deleting 33 newer ones (measured). The
count is now at least one in `prune/1` and `retention/0`, and a
`BACKUP_RETENTION` that is not a whole number of at least 1 stops the boot.

### 8. Privacy: what a backup keeps, and what a restore brings back - RECOMMENDED (policy)

Measured, not assumed:

- The reference backup held installation addresses 25 and 0 days old and a
  report address 10 days old; an installation registered 45 days earlier had
  both addresses nulled by retention before the backup.
- The scheduler writes its backup five minutes after boot and every 24 hours;
  retention runs ten minutes after boot and every 24 hours. **Every scheduled
  backup is taken five minutes before that day's retention run**, so it can hold
  addresses up to ~31 days old. Kept 30 deep, the backup set holds addresses up
  to **about two months** old.
- After a restore, an address nulled before it (the drill advanced one row's
  retention by ten days) was back in the live database - and in the backup the
  scheduler wrote five minutes after boot, before retention's first run at ten.
  So a restore re-extends those addresses by a full backup cycle.
- Never touched by retention: the entry form's email addresses, a report's
  optional contact email, and the address or range in every `block_address`
  and `unblock` action log row.
- On the VPS none of it is encrypted: the deploy sets no
  `OPENRESULTS_BACKUP_PASSPHRASE`.

Options for the operator, in rising order of effort: set the passphrase (in a
drop-in, so a deploy does not wipe it); keep fewer backups (14 halves the
window); run retention before the backup rather than after it (swap the two
first-run delays); null addresses older than 30 days in the staging copy
before it is written, as OpenPairings strips its rating lists; stop writing
the address into `block_address`'s log details.

### 9. The first boot after a restore logged `database is locked` - FIXED

`VACUUM INTO` writes a rollback-journal database; the pool's connections all
tried to switch it to WAL at once and three lost (measured: three `[error]`
lines, self-healing). `restore/1` now switches the recovered file to WAL on one
connection before handing it over, and removes any stale sidecar of an earlier
`.restored` first. Measured afterwards: no errors on first boot, no `-wal` or
`-shm` beside the file.

### 10. There was no restore procedure - FIXED (docs)

See the top. The swap was also missing the ownership step: a file written by
root is opened read-only by a non-root service (pages load, nothing saves) -
from the unit's `User=` and SQLite's documented read-only fallback, not
reproduced on Windows.

### 11. `--verify` did not accept the name `--list` prints - FIXED

The listed name, typed back in: "no such file" (measured on OpenPairings'
task, which was the same code). A bare name that matches a backup in the
backup directory now resolves to it.

### 12. Retention is thirty files, not thirty days - RECOMMENDED

Every boot writes one, and so does every manual run. The drill's instance had
four backups within twenty minutes. A day with three deploys spends three.
Also: a backup dropped into `backups/` to restore from, older than thirty
others, is deleted by the next prune (measured) - five minutes after the next
boot. Documented; the recommendation is to skip the boot-time backup when the
newest one is younger than the interval.

### Not a bug: the new tables

The backup code predates public publishing, and the brief suspected the new
tables were missing. They are not: `VACUUM INTO` copies everything. The
restored database matched the original on all 11 tables by content digest, and
a test now fails if a future change to the backup drops a row from any of them.

### Aside, outside the drill

`config/runtime.exs` binds `{0, 0, 0, 0, 0, 0, 0, 0}` in prod while this
repo's deployment guide says port 4004 is "loopback-reachable only"; on the VPS
firewalld is what makes that true. OpenPairings pinned its own listener to
loopback on 2026-09-01.

## Tests added

`test/openresults/backup_restore_test.exs`, 12 tests:

- a restored database is one this app runs on - every migration `:up` through
  `Ecto.Migrator` on the app's own Repo started against the restored file, all
  nine data tables back row for row (the public-publishing ones included), and
  `Settings`, `Installations`, `Tournaments`, `Snapshots` and `Moderation`
  reading it;
- it comes back in WAL mode with no sidecar files;
- `verify/1` refuses a correct envelope around a database failing
  `integrity_check`, and `restore/1` then writes nothing;
- PBKDF2 counts of 1 and 5,000,000,000 are refused; the count the app writes is
  honoured;
- no staging copy is left behind, accepted or refused;
- retention of 0, -1 and -3 still keeps the newest;
- the task takes a name as `--list` prints it, and prints a swap that moves the
  WAL and migrates before starting.

The swap block the task prints and every `bash` block of the new guide
sections were also run verbatim against a mock unit file, a drop-in, a
database directory with an unclean stop's sidecars, and the drill's real
before/after databases.

## The corrected procedure

It is `docs/deployment.md`, "Restoring a backup" and "What a restore undoes".
In one breath: load the unit's environment into a root shell and run `mix` as
the service account; verify (now page by page); recover beside the live file;
stop and confirm; rename the database **with** its `-wal` and `-shm`; restore
ownership; `mix ecto.migrate`; start and check for a 200; then reconcile
against the `before-restore` database and re-apply moderation, taking resurrected
tournaments down with break-glass.
