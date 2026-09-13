# Test quality, 2026-09-13

Does the suite assert the right things? OpenPairings' 2026-09-05 audit listed
that question among the areas nobody had covered, for both applications. This
pass asked it here too: a hunt for flaky tests, hand-made mutants of the
security-critical paths first, and a look for tests that never run or cannot
fail.

The same pass was run on OpenPairings, where it also found and fixed that
suite's unexplained flaky test; its report is
`openpairings/docs/test-quality-2026-09-13.md`.

## Summary

| | result |
|---|---|
| flaky tests | **none found**: 26 full runs with different seeds, all green, and nothing in the async tests that shares state. The class that caused OpenPairings' flake exists here in principle and is described below. |
| mutation sampling | 56 hand-made mutants. 48 caught by the tests nearest the code, 4 caught elsewhere in the suite, **4 survived the whole suite**, all on the security paths. Each now has an assertion that kills it (`404fc3b`), re-checked by re-running the mutant. |
| weak assertions | 2 tests confirmed unable to fail, both strengthened (`404fc3b`, `b7800bb`); more listed below |
| excluded tests | none. CI runs the whole suite. |
| production code | **unchanged. No production bug found.** Every survivor was a missing test for behaviour that is correct today, so there is no CHANGELOG entry. |
| test count | 879 before, 882 after |

Commits, on `test-quality`: `404fc3b`, `b7800bb`, and this document.

## 1. Flaky tests

Twenty-five full runs with random seeds after a baseline run, 879 tests each,
all green: seeds 469419, 615943, 414476, 388565, 600335, 659000, 87842,
191294, 953155, 861481, 420091, 474495, 277835, 31671, 917347, 638224, 220574,
616571, 495776, 545462, 940559, 173569, 988132, 275650, 851924. Each run took
about eleven seconds.

Read for the usual causes:

- **Shared state under `async: true`.** This suite runs with ExUnit's default
  concurrency, unlike OpenPairings'. The twelve async modules (changelog,
  address blocks, installations, registrations, catalogue, client address, JWT,
  error pages, format, tournament status, tournament) touch no application
  environment, no ETS cache and no rate limiter. Every test that calls
  `RateLimit.reset/0`, moves an `Application` setting or reads a cache is in an
  `async: false` module. The database pool is one connection, so async tests
  queue on it rather than race.
- **Wall-clock time.** `Tournament.status/2` takes `today` explicitly and its
  tests pin it; the JWT tests leave generous margins around `exp`, `nbf` and
  `iat` (and the new boundary test pins `:now`).
- **Leftovers in the test database** - OpenPairings' actual flake. That
  checkout's `pairings_engine_test.db` held users committed by
  `MIX_ENV=test mix run` probes, and fixture addresses built from
  `System.unique_integer/0` recur on every boot, so a random test collided with
  one now and then. `openresults_test.db` is exposed the same way in principle.
  Here it is much less likely to bite: `unique_slug/1` adds a `:rand` component
  and keys are random bytes. The main checkout's database holds no rows today.
  If probes are ever run against it, OpenPairings' `PairingsEngine.Test.LeftoverRows`
  (clear committed rows before the Sandbox takes over) ports as it is.

## 2. Mutation sampling

### Method

No mutation-testing dependency. A small script applied one mutation at a time
to this worktree, ran the test files nearest the code, and if they stayed green
ran the whole suite; the original bytes were written back in a `finally`, and
`git diff` checked clean after every mutant. Nothing mutated was committed:
every commit in this pass touches `test/` and `docs/` only. `moderation.ex` was
mutated only in the transfer functions, and never committed.

Areas, in the brief's order: `IngestAuth` and the installation opt-in
(default-deny); installation ownership (`not_owner`); `TournamentKeys` including
break-glass; `AdminAccess.JWT` and `Plugs.AdminAuth`; visibility (pending,
listed, hidden) on public surfaces; rate limits and address blocks; moderation
transfers. Backup code was left out.

"Caught, outside the targeted files": TK2, TK4, TK6 and TK7 are caught by
`InstallationAccessTest` and `ModerationTest`, which is where those rules are
tested; the targeted list for `TournamentKeys` simply did not include them.

### Results

| | mutants |
|---|---|
| caught by the targeted tests | 48 |
| caught, outside the targeted files | 4 |
| **survived the whole suite** | **4** |
| total | 56 |

| # | area / file | mutation | verdict | caught by / fix |
|---|---|---|---|---|
| IA1 | `ingest_auth.ex` | default-deny dropped: a key is a credential on a route that did not opt in | caught | `DefaultDenyTest`: IngestAuth, called bare on a conn with no opt-in, refuses the key |
| IA2 | `ingest_auth.ex` | an opted-in route skips the per-action checks | caught | `DefaultDenyTest`: a route that did not opt in an action nobody checks is refused rather than trusted |
| IA3 | `ingest_auth.ex` | installation keys honoured with the environment gate off | caught | `PublicPublishingGateTest`: an orik_ key is the anonymous 401 on every ingest route, even its own tournament's |
| IA4 | `ingest_auth.ex` | an unconfigured server accepts any bearer token (fails open) | caught | `SnapshotControllerTest`: POST /api/snapshots authentication refuses everything when the server has no token configured |
| IX1 | `installation_access.ex` | a revoked key may still read history | caught | `InstallationAccessTest`: suspended and revoked revoke: mint, publish, history and registrations are installation_revoked; delete still works |
| IX2 | `installation_access.ex` | a suspended key may still read history and registrations | caught | `InstallationAccessTest`: suspended and revoked suspend: mint, publish, history and registrations are installation_suspended; delete still works |
| IX3 | `installation_access.ex` | an unknown installation status is permission | **survived** | new test `InstallationAccessTest`: a status this version does not know is not permission (404fc3b); mutant now fails |
| IX4 | `installation_access.ex` | history/registrations skip the owner check (not_owner) | caught | `InstallationAccessTest`: an installation key cannot touch a tournament that is not its own publish, delete, history and registrations are all not_owner, and nothing changes |
| IX5 | `installation_access.ex` | mint and publish get separate budgets | caught | `InstallationAccessTest`: the publish budget 30 a minute per installation, then rate_limited with Retry-After |
| IX6 | `installation_access.ex` | an address block no longer stops minting | caught | `InstallationAccessTest`: address blocks refuse publish and mint from the address; the operator token is exempt; delete works |
| IX7 | `installation_access.ex` | the pause no longer stops publishing | caught | `InstallationAccessTest`: publishing_paused refuses publish and mint for installation keys only; delete still works |
| IX8 | `installation_access.ex` | the delete owner check skipped | caught | `InstallationAccessTest`: suspended and revoked suspend: mint, publish, history and registrations are installation_suspended; delete still works |
| TK1 | `tournament_keys.ex` | a claimed slug accepts a keyless publish (takeover by omission) | caught | `TournamentKeyTest`: tournaments published before keys existed a legacy slug is adopted by the first publish that carries a key |
| TK2 | `tournament_keys.ex` | break-glass on an unclaimed slug without the operator credential | caught, outside the targeted files | `InstallationAccessTest`: break-glass and on an unclaimed slug it is refused rather than stored as the tournament's key |
| TK3 | `tournament_keys.ex` | a read claims an unclaimed slug | **survived** | new test `TournamentKeyTest`: reading never claims an unclaimed slug (now pulls WITH a key) (404fc3b); mutant now fails |
| TK4 | `tournament_keys.ex` | break-glass on a claimed slug without the operator credential | caught, outside the targeted files | `InstallationAccessTest`: break-glass the operator token in X-OpenResults-Key does nothing for an installation credential |
| TK5 | `tournament_keys.ex` | a whitespace-only key is a key | caught | `TournamentKeyTest`: claiming a slug a blank key is treated as no key, and never claims a slug |
| TK6 | `tournament_keys.ex` | break-glass is not logged to the moderation log | caught, outside the targeted files | `InstallationAccessTest`: break-glass the operator token still is break-glass, and the action log records it |
| TK7 | `snapshot_controller.ex` | delete honours break-glass for an installation credential | caught, outside the targeted files | `InstallationAccessTest`: break-glass the operator token in X-OpenResults-Key does nothing for an installation credential |
| J1 | `jwt.ex` | a token with crit is accepted | caught | `JWTTest`: the algorithm is never the token's to choose a header naming critical extensions is refused |
| J2 | `jwt.ex` | expiry boundary moved by one second | **survived** | new test `JWTTest`: expiry is exact at the edge of the leeway, not a second later (404fc3b); mutant now fails |
| J3 | `jwt.ex` | iat in the future accepted | caught | `JWTTest`: the claims, once the signature holds issued in the future |
| J4 | `jwt.ex` | any audience list accepted | caught | `JWTTest`: the claims, once the signature holds wrong audience |
| J5 | `jwt.ex` | any issuer accepted | caught | `JWTTest`: the claims, once the signature holds wrong issuer - another team, or the right host without https |
| J6 | `jwt.ex` | a token without exp/nbf/iat is valid | caught | `JWTTest`: the claims, once the signature holds missing any of exp, nbf or iat |
| J7 | `jwt.ex` | a signature that makes the crypto library raise is accepted | **survived** | new test `JWTTest`: a signature the crypto library cannot even check is refused, not waved through (404fc3b); mutant now fails |
| J8 | `jwt.ex` | nbf not enforced | caught | `JWTTest`: the claims, once the signature holds not valid before a time still in the future |
| AA1 | `admin_auth.ex` | any email with a valid token is admitted | caught | `AdminAuthTest`: a valid token whose email is not on the list is a plain 403 that names the email and no configuration |
| AA2 | `config.ex` | the development bypass honoured in production | caught | `AdminAuthTest`: the development bypass is ignored outside dev and test even when configured |
| AA3 | `config.ex` | admin emails compared case-sensitively | caught | `AdminAuthTest`: a valid token for a listed admin matches the list case-insensitively, with the list's spacing trimmed |
| AA4 | `config.ex` | a production node boots with the bypass configured | caught | `AdminAuthTest`: the development bypass the guard fails closed when the environment is not configured at all |
| V1 | `tournaments.ex` | public_latest serves a hidden tournament | caught | `VisibilityTest`: the report link is not on a 404 for a slug nobody published, nor for a hidden one |
| V2 | `snapshots.ex` | pending tournaments reach the front page and player pages | caught | `TournamentsTest`: Snapshots.list_current(listed_only: true) leaves pending and hidden tournaments out in the query; without the option nothing is left out |
| V3 | `player_history.ex` | player pages read every tournament, not only listed ones | caught | `VisibilityTest`: a hidden tournament is absent from the front page and from player pages |
| V4 | `visibility.ex` | noindex set for hidden instead of pending pages | caught | `VisibilityTest`: a pending tournament is reachable on every page, and every response carries noindex |
| V5 | `snapshot_controller.ex` | the JSON API does not mark a pending tournament noindex | caught | `VisibilityTest`: a pending tournament is reachable on every page, and every response carries noindex |
| V6 | `tournaments.ex` | an owner may publish to its hidden tournament | caught | `TournamentsTest`: publishing with an installation only to its own slug, and never to a hidden one |
| V7 | `tournaments.ex` | not_owner dropped: every installation owns every row | caught | `TournamentsTest`: publishing with an installation only to its own slug, and never to a hidden one |
| V8 | `registration_controller.ex` | the FIDE search answers for a hidden tournament | caught | `VisibilityTest`: a hidden tournament 404s on every public surface exactly like a slug that never published |
| V9 | `tournaments.ex` | tournament limit off by one | caught | `TournamentsTest`: mint/2 the limit counts pending and listed, not hidden |
| V10 | `tournaments.ex` | a slug with no row reads as pending instead of listed | caught | `TournamentsTest`: status/1 a takedown leaves the slug reading as no row, not as its old status |
| R1 | `rate_limit.ex` | rate limit lets one extra request through | caught | `RateLimitTest`: the sweep reclaims windows that have ended and leaves the current one alone |
| R2 | `installation_controller.ex` | IPv6 registration budget keyed on the full address, not the /64 | caught | `PublicPublishingApiTest`: POST /api/installations counts an IPv6 client by its /64 |
| R3 | `installation_controller.ex` | registration budget spent before the closed switch is checked | caught | `PublicPublishingApiTest`: POST /api/installations a refusal for a closed switch does not spend the address's budget |
| R4 | `installation_controller.ex` | no server-wide registration budget | caught | `PublicPublishingApiTest`: POST /api/installations allows 200 in total per day, across addresses |
| R5 | `registration_controller.ex` | entry-form rate limit keyed on the peer address (one bucket behind the tunnel) | caught | `RegistrationControllerTest`: the rate limit counts visitors behind the tunnel one by one, not all as one |
| R6 | `installation_controller.ex` | an address block no longer stops registration | caught | `PublicPublishingApiTest`: POST /api/installations is address_blocked from a blocked address, before the switch is even considered |
| R7 | `address_blocks.ex` | an expired block still blocks | caught | `AddressBlocksTest`: blocks blocked? only while a block is live |
| R8 | `cidr.ex` | v4-mapped IPv6 clients escape IPv4 blocks | caught | `AddressBlocksTest`: CIDR, IPv4 reads a v4-mapped IPv6 address as the IPv4 address it carries, both ways |
| M1 | `moderation.ex` | a single transfer accepts a suspended target | caught | `ModerationTest`: transfer/3 refuses an unknown tournament, an unknown installation and a revoked one |
| M2 | `moderation.ex` | transfer_all accepts a revoked or suspended target | caught | `ModerationTransferAllTest`: refusals, with nothing moved and nothing logged to a revoked installation |
| M3 | `moderation.ex` | transfer_all leaves hidden tournaments behind | caught | `ModerationTransferAllTest`: all or nothing a failure on the last tournament rolls back every move, key and log row |
| M4 | `tournaments.ex` | a transfer keeps the old tournament key claim | caught | `ModerationTransferAllTest`: moving everything the new laptop's next keyed publish claims a moved tournament; the old key is refused |
| M5 | `moderation.ex` | transfer_all from an installation to itself allowed | caught | `ModerationTransferAllTest`: refusals, with nothing moved and nothing logged to itself |
| M6 | `moderation.ex` | transfer_all writes no per-tournament transfer rows | caught | `ModerationTransferAllTest`: moving everything every tournament, in every status, each exactly as transfer/3 would move it |
| M7 | `moderation.ex` | a single transfer is not logged | caught | `ModerationTest`: transfer/3 rebinds ownership and clears the stored key, so the target's next keyed publish claims it |

### The four survivors

1. **IX3 - an installation status nobody knows is permission.**
   `InstallationAccess` ends its status clauses with "a status this code has
   never heard of is not permission" and refuses it as revoked. Nothing tested
   it, and nothing in the table constrains the column: a hand-edited row, or a
   status a later version adds before a rollback, would have reached every write
   route had that clause gone. New test: a key whose row says `frozen` is
   refused on mint, publish, history and registrations.
2. **TK3 - a keyed read claiming an unclaimed slug.** The test "reading never
   claims an unclaimed slug" pulled the queue with no key, and a request with no
   key has nothing it could claim with, so the refute held whatever the read path
   did. It now also pulls with a key, refutes the claim, and proves the real
   publisher can still claim the slug.
3. **J2 - a token accepted for one second past `exp` + leeway.** The boundary
   itself was untested: the tests sat 5 seconds inside it and 1 second outside.
   New test pins `:now` and checks both sides of the edge.
4. **J7 - a signature whose check raises is waved through.**
   `:public_key.verify/4` raises, rather than answering false, for a key term that
   is not an RSA public key. The rescue answers `:bad_signature`; had it answered
   `:ok`, every such token would have been admitted, and no test would have
   noticed. New test covers a garbage key term and signatures of the wrong size.

## 3. Tests that never run, or assert nothing

### Excluded tests, and CI

None. `test/test_helper.exs` is `ExUnit.start()` with no exclusions, and
`.github/workflows/elixir.yml` runs a plain `mix test`, so CI runs all 882. The
only module tag in use is `:capture_log`.

One dependency worth knowing about: `test/fixtures/snapshot_swiss.json` and
`snapshot_keizer.json` are **written by OpenPairings' test suite**
(`SnapshotTest`, "a real snapshot is written to the OpenResults fixture
directory") whenever it runs in a checkout with this one beside it. They are the
contract, and nothing checks them against OpenPairings' builder here; drift
shows up only when someone runs that suite next to this checkout and commits
what it wrote.

### Weak assertions, fixed

Each was confirmed by breaking the code under it and watching it stay green.

| test | why it could not fail | fix |
|---|---|---|
| `TournamentKeyTest` "reading never claims an unclaimed slug" | pulled with no key, which can never claim (mutant TK3) | pulls with a key too, `404fc3b` |
| `DisplayRulesTest` "byes can be hidden without hiding the boards" | asked round 1, which has no byes in the fixture, and refuted the CSS selector `"table.byes"` rather than markup; forcing byes on left it green. Its positive half asserted `html =~ "table"`. | reads round 2, proves the byes table is there before hiding it, and that the pairings table stays, `b7800bb` |

### Weak or odd, listed and not changed

- `DisplayRulesTest` "each disappears on its own without taking the others"
  checks that the rest of the row survives with `html =~ "GER"` and
  `html =~ "GM"`, bare strings that other text on the page can satisfy. Its
  `refute html =~ "SF Berlin"`, the part that matters, is sound.
- `DisplayRulesTest` several tests assert `html =~ "Standings"` as their
  "the page still works" half, which any page of the site satisfies. The
  refutes beside them are the real checks, and the values they refute (2601,
  2033, "SF Berlin", "Category A" once rendered) are all in the fixture.
- `AdminActionsTest` "and so does a query string" and `AdminPagesTest` "filters
  that make no sense are ignored rather than fatal" assert only the status. That
  is the property ("does not crash"), so they are not weak.
- `ModerationTest` compiles with an unused-variable warning (line 304).

### Skipped, tagged, and swallowed

- No `@tag :skip` or `@moduletag :skip`.
- No test swallows a failure. The only `try` blocks are cleanup in
  `backup_restore_test.exs`.

## How to repeat this

The scripts were kept out of the repository; see the OpenPairings report for the
method, which is the same here. On this suite every mutant, including the full
run for a survivor, takes under fifteen seconds.
