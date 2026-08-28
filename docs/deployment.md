# Deployment

How the public half is run in production, and the two things a person has to
do by hand that no script can do for them.

For the arbiter's app see
[OpenPairings' own `docs/deployment.md`](https://github.com/AuroraRyunix/openpairings/blob/main/docs/deployment.md).
The two apps share a host, a deploy script and nothing else.

## Where it runs

| | |
| --- | --- |
| public URL | `https://openresults.zerotwo.cloud` |
| internal port | **4004**, plain HTTP, loopback-reachable only |
| app tree | `/apps/web/openresults` |
| systemd unit | `openresults.service` |
| database | `/var/lib/openresults/openresults.db` |

Same host and same deployment model as OpenPairings: not containerized, not
orchestrated - upload the source, compile it on the target, run it under
`systemd` with `MIX_ENV=prod`. This document omits the host's address, SSH
details and every credential; those live outside version control.

## Deploying

The deploy script is `deploy_openpairings.py`, kept on the maintainer's
machine rather than in either repository (it embeds host-specific paths and
reads credentials from a `.env` beside itself). It knows both apps:

```bash
python deploy_openpairings.py --openresults     # this app only
python deploy_openpairings.py                   # OpenPairings only (the default)
python deploy_openpairings.py --both            # both, in that order
```

**The two are independent.** Separate trees, separate units, separate
databases, separate `SECRET_KEY_BASE`. Deploying one neither touches nor
restarts the other, which is the point: the reason for the split is that a
busy results page and a live pairing session should not be able to take each
other down, and that would be a hollow promise if every deploy restarted
both.

What a run of `--openresults` does, in order:

1. **Checks port 4004 is free** (or already held by `openresults.service`
   itself) before uploading anything. Pointing a unit at an occupied port
   does not fail loudly - systemd starts it, Bandit cannot bind, the app
   dies, systemd restarts it forever - so this is checked first, while the
   answer is still cheap.
2. **Uploads the app tree by SFTP**, skipping `.git`, `_build`, `deps`,
   `node_modules`, `.env`, `erl_crash.dump` and every `*.db` file. Dev and
   test databases are never uploaded.
3. **Builds on the target**: `deps.get --only prod`, `compile`,
   `assets.setup`, `assets.deploy` - with a short-lived, root-only env file
   supplying `DATABASE_PATH`/`SECRET_KEY_BASE`/`PHX_HOST`, deleted
   immediately afterwards even on failure.
4. **Creates the database if absent and migrates it.** `ecto.create` is
   best-effort (it exists for a first deploy); `ecto.migrate` is not.
5. **Writes `openresults.service`** with the production environment in
   `Environment=` lines, `chmod 600` because one of them is
   `SECRET_KEY_BASE` and another is the ingest token. As on the other app, a
   `SECRET_KEY_BASE` from a prior deploy is **reused** rather than
   regenerated.
6. **Restarts, then proves it came back** - see below.

**Any failing build step stops the deploy** and leaves the old release
running, untouched and still serving. A deploy that could not build is a
deploy that has not happened.

### No countdown banner here

OpenPairings warns everyone with a page open before it restarts. This app
does not, and the absence is deliberate. There are no accounts, no sessions
and no half-filled forms held in server memory on the reading path, so there
is nobody to warn and nothing for them to save. The cost of this app
restarting is that somebody refreshes.

## Verifying, and why it is not optional

On **2026-08-28** the deploy script printed "Deployment Completed
Successfully!" directly underneath a `systemctl status` block showing the
service dead, and the site stayed down for six minutes past the window users
had been promised. The script restarted the service and never asked whether
it came back.

So the deploy is not finished when `systemctl restart` returns. It is
finished when the app answers. After every restart the script polls, up to
`DEPLOY_HEALTH_TIMEOUT` seconds (default 90), on two signals:

- **systemd.** `failed` or `inactive` means it is not coming back, and
  `NRestarts` above zero means it booted, died, and is being restarted in a
  loop. Either verdict is returned immediately rather than waiting out the
  timeout for news that has already arrived.
- **HTTP.** `active` only proves a process exists. So it also asks the app
  itself, over loopback.

If neither succeeds inside the timeout, the script dumps `systemctl status`
and the last 60 journal lines and **exits non-zero**.

The HTTP check accepts **any status code that is not `000` and not a `5xx`** -
not `200`. `curl` reports `000` when it got no response at all, and that,
plus a server error, is the real negative. Demanding `200` would be worse
than useless: on OpenPairings `GET /` is a `302` to the login page, and on
either app a request carrying the public `Host` header answers `301` from
`force_ssl`. A check that called those failures would fail every healthy
deploy.

This app's `GET /` is a genuine `200` (the list of published tournaments,
empty or not) because `config/prod.exs` excludes `localhost` and `127.0.0.1`
from `force_ssl`. That exclusion is what makes a plain-HTTP health check
possible at all; keep it.

### The `deps.get` failure, and its one automatic recovery

The 2026-08-28 outage started as a dependency fetch. `mix.lock` moved a git
dependency to a new tag, that dependency's checkout under `deps/` had a stray
local edit, git refused to move a dirty working tree onto a different commit,
and `deps.get` aborted - taking `compile`, `assets.deploy` and `ecto.migrate`
down with it. Both apps carry git dependencies (`heroicons`, `daisyui`, and
`ainalrami` on the OpenPairings side), so the shape will recur.

A dirty checkout under `deps/` is never worth keeping: it is a cache of
somebody else's source. When `deps.get` fails, the script finds the dirty
checkouts, throws each away, and retries **once**.

```
mix deps.clean <dep>           removes deps/<dep> AND its build artifacts,
                               so the next deps.get re-clones clean. This is
                               the one that fixes it.

mix deps.clean --build <dep>   removes ONLY the build artifacts and leaves
                               deps/<dep> exactly as dirty as it was.
```

`--build` is the trap. It sounds like the more thorough of the two, and it
leaves the actual problem in place - the retry fails with the identical
message and it looks as though the recovery did nothing.

Only checkouts that are genuinely dirty are cleaned; a blanket
`deps.clean --all` would re-fetch and rebuild everything and turn a
thirty-second recovery into a long outage. And exactly one retry, never a
loop: if a clean re-fetch still cannot resolve the tree, the problem is the
lock file or the network, and grinding away only delays the moment the deploy
admits it is stuck.

## Production database

`DATABASE_PATH` points at `/var/lib/openresults/openresults.db`, **outside**
the uploaded app tree, so that re-running the deploy (which re-uploads the
whole app directory) can never touch it. Every deploy leaves the file alone
except for `ecto.migrate` applying new migrations.

The data here is not precious in the way the arbiter's database is - every
snapshot came from an arbiter's machine, which remains the source of truth
and can republish. The registration queue is the exception: an entry a
spectator typed in exists only here until an arbiter pulls it.

## Configuration (environment variables)

All read in `config/runtime.exs`.

| Variable | Required in prod? | Purpose |
| --- | --- | --- |
| `DATABASE_PATH` | yes | absolute path to the SQLite file; the app refuses to boot without it |
| `SECRET_KEY_BASE` | yes | cookie/session signing - generate once, keep stable |
| `PHX_HOST` | yes | public hostname; drives generated absolute URLs |
| `PHX_SERVER` | yes (`true`) | actually serve HTTP |
| `PORT` | no (default 4000) | internal HTTP port - **the unit sets 4004**, see below |
| `OPENRESULTS_INGEST_TOKEN` | effectively | the bearer token an arbiter publishes with. Unset means every publish is refused with a 401 |
| `POOL_SIZE` | no (default 5) | Ecto connection pool size |
| `DNS_CLUSTER_QUERY` | no | multi-node clustering, unused here |

Notably absent, compared with OpenPairings: **no SMTP** (this app sends no
mail, and has no account-recovery path to send it for) and **no Keycloak**
(no accounts at all).

### `OPENRESULTS_INGEST_TOKEN` is only on this side

The token is the whole of the trust boundary on the write path: anything
holding it can publish a tournament page, and nothing else can.
`OpenResultsWeb.Plugs.IngestAuth` compares it in constant time and fails
closed - a missing header, a wrong token and an unconfigured server all
produce the same 401.

The asymmetry is deliberate and worth stating plainly, because it is the
thing people get wrong: **OpenPairings does not read this variable.** An
arbiter types the endpoint and the token into that app's Settings page and
they are stored in that machine's own database
(`PairingsEngine.Publishing.put_endpoint/1` and `put_token/1`), because a
laptop in a school gym has no systemd unit to put them in. Setting
`OPENRESULTS_INGEST_TOKEN` on the server configures the *receiver*; the
*sender* is configured through the UI. See the manual steps below.

Unset, the app still boots and still serves every tournament already
published - only publishing is refused. That is the right failure: the read
side keeps working while the token is sorted out.

### It is also the break-glass key

The ingest token no longer settles who may touch a given tournament. Each
tournament is claimed by a per-tournament key the arbiter's machine generates
and sends in `X-OpenResults-Key`; this server keeps only a SHA-256 digest of
it. See `docs/snapshot-schema.md` for the contract and
`OpenResults.TournamentKeys` for the reasoning.

That leaves one operational hole - **the key lives on one laptop, and laptops
die** - so the ingest token doubles as the override. Send it *in the
tournament-key header* and the key check is bypassed:

```bash
# Republish a tournament whose key was lost with the machine that held it.
curl -X POST https://openresults.zerotwo.cloud/api/snapshots \
  -H "Authorization: Bearer $OPENRESULTS_INGEST_TOKEN" \
  -H "X-OpenResults-Key: $OPENRESULTS_INGEST_TOKEN" \
  -H 'Content-Type: application/json' --data @snapshot.json

# Or take it down entirely: every snapshot, the whole history, the
# registration queue and the key claim.
curl -X DELETE https://openresults.zerotwo.cloud/api/tournaments/<slug> \
  -H "Authorization: Bearer $OPENRESULTS_INGEST_TOKEN" \
  -H "X-OpenResults-Key: $OPENRESULTS_INGEST_TOKEN"
```

**Every override is logged**, at warning level, with the slug and the action:

```
[warning] BREAK-GLASS: publish on "gent-spring-open-2026" authorised with the
server-wide ingest token instead of the tournament key - ...
```

`journalctl -u openresults -g BREAK-GLASS` finds them. If that line appears
and nobody on the team was holding the glass hammer, the ingest token has
leaked and is the thing to rotate.

Rotating the ingest token is safe for the tournaments themselves: it is not
stored as anybody's tournament key (break-glass deliberately never claims a
slug), so rotating it costs each arbiter a visit to their Settings page and
costs no tournament its claim.

## Ports on this host

Nothing is reachable from the internet except SSH - firewalld's public zone
opens exactly one port, and every public hostname arrives through the
Cloudflare tunnel, which dials these over loopback. A port number here is not
a security boundary, only a promise not to collide with a neighbour.

| Port | Service |
| --- | --- |
| 3000 | `dataplatform-api.service` |
| 4001 | `pairingsengine.service` - OpenPairings |
| 4002 | `personalsite.service` (`python3 -m http.server`) |
| 4003 | `kbsb-database-manager.service` |
| **4004** | **`openresults.service` - this app** |
| 5432 | PostgreSQL |
| 8080 | nginx, in front of Keycloak on 8081 |
| 8099 | nginx default server |

**Why 4004.** This app's *dev* config defaults to 4002 so both halves of the
split can run side by side on one laptop. On this host 4002 is taken by the
personal site and 4003 by the KBSB database manager, so production takes
4004: the first free port in the same block, which keeps the two halves of
the split adjacent and easy to remember.

**Why not 4000,** which is also free. 4000 is what `mix phx.server` binds when
`PORT` is unset, so anything that loses its `PORT=` line - a stray dev server,
a hand-edited unit, a release someone runs by hand to check something - lands
there. Leaving it unclaimed means that accident collides with nothing instead
of quietly stealing traffic from a live service.

Override with `DEPLOY_OPENRESULTS_PORT` in the deploy script's `.env` if this
ever has to move; the script checks the port is actually free before it
uploads anything.

## Reverse proxy / TLS

The app listens on plain HTTP on 4004. TLS termination and the public
hostname both happen in **cloudflared**, which runs on the box as
`cloudflared.service` and dials 4004 over loopback. nginx is on this host but
is not involved - it fronts Keycloak only.

`config/prod.exs` sets `force_ssl` with `rewrite_on: [:x_forwarded_proto]`, so
the app trusts the forwarded-proto header the tunnel sets rather than
terminating TLS itself. `localhost` and `127.0.0.1` are excluded from it,
which is what lets the deploy's health check speak plain HTTP over loopback.

## Manual steps a script cannot do

Two, both one-time.

### 1. Add the hostname in the Cloudflare dashboard

**This cannot be automated from the box, and it is not an oversight.** The
tunnel is run token-based:

```
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token <token>
```

There is no `config.yml`, no `/etc/cloudflared` ingress file, nothing on the
server that says which hostname maps to which port. A token-based tunnel
fetches its entire routing table from Cloudflare at connect time, so the
routing lives in the dashboard and the dashboard is the only place it can be
edited. Writing an ingress file on the box would change nothing.

In **Cloudflare Zero Trust → Networks → Tunnels →** the tunnel serving
`zerotwo.cloud` **→ Public Hostnames → Add a public hostname**:

| Field | Value |
| --- | --- |
| Subdomain | `openresults` |
| Domain | `zerotwo.cloud` |
| Path | *(empty)* |
| Type | `HTTP` |
| URL | `localhost:4004` |

`HTTP`, not `HTTPS`: the tunnel terminates TLS at Cloudflare's edge and
speaks plain HTTP to the app, which is exactly what `force_ssl`'s
`x_forwarded_proto` rewrite expects. Setting `HTTPS` here points the tunnel
at a TLS listener that does not exist.

The DNS record is created for you when the hostname is added to a zone
Cloudflare already manages. Nothing on the box needs restarting - the tunnel
picks the new route up on its own.

The `PORT` in the unit and the port in this mapping have to agree. If one
moves, move both.

The tunnel token itself is not recorded in this repository, in the deploy
script, or anywhere else in version control, and must not be.

### 2. Point OpenPairings at this server

In **OpenPairings → Settings → the publishing card**, set:

- **endpoint**: `https://openresults.zerotwo.cloud`
- **token**: the same value as `OPENRESULTS_INGEST_TOKEN` on this server

Both halves are required - `PairingsEngine.Publishing.configured?/0` returns
false unless each is a non-empty string, because an endpoint with no token
would fail every send with a 401, which is a worse experience than saying so
up front. Publishing is then per-tournament, opt-in, via that tournament's
**Publish to OpenResults** toggle.

This step exists because, as above, the sender keeps its configuration in its
own database rather than in the environment. The deploy script prints a
reminder after a successful `--openresults` run.

## Secrets

Nothing production-sensitive is committed to this repository.

- The deploy script lives outside both repos and reads credentials from its
  own local, gitignored `.env`.
- The systemd unit (containing `SECRET_KEY_BASE` and
  `OPENRESULTS_INGEST_TOKEN`) is `chmod 600`, root-only.
- `config/config.exs` sets `:ingest_token` to `nil` on purpose: a default
  that works is a default that reaches production.
- The Cloudflare tunnel token exists only in `cloudflared.service` on the
  box. Note that it is therefore visible in that unit's `ExecStart` and in
  `ps` output to anyone who can read them; that is a property of token-based
  tunnels, not something this app chose.

Long-lived, hand-managed environment values belong in a drop-in under
`/etc/systemd/system/openresults.service.d/`, **not** in the unit itself: the
deploy rewrites `openresults.service` on every run and anything hand-added
there is wiped. (This is how `KEYCLOAK_*` is handled on the OpenPairings
side.)

## Setting up a fresh host

A target reachable over SSH, plus Java + Erlang + Elixir (the deploy script
installs these if absent on a Rocky/RHEL-family target), a free port, and a
hostname routed to it. No SMTP account and no identity provider are needed -
this app has neither.
