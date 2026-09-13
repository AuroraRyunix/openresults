# Stats overhead, 2026-09-13: what `/admin/stats` costs the request path

The admin stats page (`OpenResults.Stats`) counts every request. This is the
measurement that it does not undo the throughput work of
[`load-test-2026-09-12.md`](load-test-2026-09-12.md), and the record of the
one design change the measurement forced.

Same box and method as that document: Intel Core i7-10700, Windows 11 IoT
Enterprise LTSC 2024, Erlang/OTP 29 (erts 17.0.5), Elixir 1.20.3, Bandit
1.12.5; `MIX_ENV=prod mix phx.server` after `mix assets.deploy`, one
scheduler (`+S 1:1`), `ProcessorAffinity = 1` (core 0), `POOL_SIZE=5`, the
same generated 128-player, 9-round tournament published through
`POST /api/snapshots`, every page warmed once, then the §3 load generator in
`--mode fresh` with `Accept-Encoding: gzip`, 8 seconds a step.

## What was compared, and how

**Base** is `main` at `6643a3f`; **stats** is the `admin-stats` branch. Both
were built in production mode in their own checkouts.

Two changes to the method, both to make a difference of a few percent
visible at all:

1. **Both servers run at the same time**, each pinned to core 0 with one
   scheduler, on ports 4004 and 4005, and only one is under load at any
   moment. The steps alternate base, stats, stats, base, ... so whatever
   else the desktop is doing lands on both alike. A run of four to six such
   pairs per concurrency is one sample.
2. **The load client is kept off core 0 and its hyperthread sibling**
   (`start /affinity FFFC`). In 2026-09-12's runs the client could be
   scheduled onto the server's own core.

Server CPU time was read from the process before and after each step, so
each step also gives **requests per CPU-second**, which does not move when
something else takes a slice of core 0.

**The noise floor, measured**: base against base (both ports running
`6643a3f`, four pairs) came out +1.6% to +2.9% in favour of the second
port. A difference under about 3% is inside what this method can tell apart.

## Results

Requests per second, mean over the pairs, and the server's requests per
CPU-second:

| Run | Pairs | c10 base | c10 stats | c10 | c50 base | c50 stats | c50 | req/CPU-s c10 | req/CPU-s c50 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| A/A (base on both ports) | 4 | 6421 | 6610 | +2.9% | 5328 | 5440 | +2.1% | +1.8% | +2.9% |
| first design | 6 | 6420 | 6067 | **-5.5%** | 5758 | 5230 | **-9.2%** | -5.8% | -8.5% |
| first design, request handler detached | 4 | 6085 | 6034 | -0.8% | 5137 | 5070 | -1.3% | -1.9% | -1.8% |
| final design, four runs pooled | 24 | 6033 | 5998 | **-0.6%** | 5429 | 5336 | **-1.7%** | -1.2% | -1.7% |

The four pooled runs, one by one (c10 / c50): -0.4% / +2.2%, -0.8% / -4.5%,
+1.6% / -0.5%, -2.8% / -3.9%. The last two changes below landed between
them: the third run already counted connections in their own process, and
only the fourth had rows per scheduler (the committed code). Stats was behind in 17 of 24 pairs at c10 and
18 of 24 at c50, so there is a real cost, and it is small: about 1-2% on
the pooled means, where the first design lost 5-9%. The median pair is
-1.5% at c10 and -3.2% at c50; single runs swing more than the difference
being measured.

Zero errors on the stats server in every step. Absolute numbers are a
little below 2026-09-12's §8.7 (6483 at c10, 5670 at c50) because the desktop
was busier today: the base build was measured alongside, under the same
conditions, rather than taken from that document.

### Inside the server: what one request costs now

Measured on the running production-mode node over distribution, with a real
conn captured from a page-cache hit under load and the handler called
500,000 times after the load stopped (before rows per scheduler, which add
about 50 ns in isolation):

| | per call |
|---|---:|
| the request handler itself | 529 ns |
| `:telemetry.execute` of Bandit's stop event, handler attached | 704 ns |
| the same with no handler attached | 105 ns |
| the page cache's decision, `put_private` in `Revalidate` | 33 ns |
| the collector's work in 20 seconds at c50 | 31,404 reductions of 321 million (0.01%) |

About 0.6 microseconds a request, against the ~160-190 microseconds a
request costs at these rates: 0.3-0.4%. The pooled 1-2% above is larger
than that; the method cannot say whether the rest is real or noise.

### Two schedulers, a spot check

`+S 2:2` on two physical cores (CPUs 0 and 2), client off CPUs 0-3, five
pairs: c10 9485 base, 9023 stats (-4.9%, but the steps ranged from 7,900
to 11,000 on both builds); c50 9678 base, 9689 stats (+0.1%). Too noisy to
put a number on, and no sign of the two schedulers fighting over the
counters (see "per scheduler" below).

## What the first design did wrong, and what changed

The first version counted a request with two ETS increments and a page view
with a third: the request row (status class and duration bucket), a
separate page-cache row from `Revalidate`, and the slug. Each call built its
position list and read the clock. Isolated on this box: 620 ns for the
handler and 175 ns for the page-cache increment. Measured on the server: 5-9%
of throughput. Detaching only the handler at runtime brought it back to
within noise, which put the cost in the handler.

The final design:

- **One increment per request.** The page cache's decision rides to the
  handler in `conn.private` (`Revalidate` puts `:hit`, `:miss` or
  `:not_modified` there) and is counted in the request's own row, in the
  same `update_counter/3` as the status class and the duration bucket.
- **No allocation for the position list.** All 320 lists (5 status classes
  x 16 duration buckets x 4 cache decisions) are built at compile time and
  picked with `elem/2`.
- **One clock read**, `System.os_time(:second)` (70 ns on Windows), shared by
  the request and the slug increment.
- **Rows per scheduler.** Keys end in `:erlang.system_info(:scheduler_id)`
  (10 ns), so on the 2 vCPU box two schedulers never take the same row lock
  for the same minute. The collector adds them together.
- **The connection count moved off the collector.** Counting open
  connections asks each of Thousand Island's 100 acceptor supervisors in
  turn; at c50 on one core that took 1.7 seconds of waiting, during which a
  tick or the admin page would have waited too. It now runs in a process of
  its own and reports back.

Isolated, the handler went from 620 + 175 ns to 575 + 33 ns.

## One thing not to do: attach or detach handlers at runtime

`:telemetry` keeps its handler table in `persistent_term`, and changing a
`persistent_term` costs every process a scan. Toggling the handler between
steps made the step right after each toggle about 5% slower, whichever way it
went. `OpenResultsWeb.StatsTelemetry.attach/0` runs once, at boot, and
nothing detaches it.

## Memory bounds

- **The counter table**: 6 rows a scheduler a minute (5 route groups and
  the Repo), events, and at most 2,000 slug rows a minute. The collector
  takes a minute's rows out as soon as it ends, so at most two minutes are
  held: about 400 KB in the worst case of 2,000 distinct tournaments read in
  one minute.
- **The collector**: 61 minute buckets and 96 quarter-hour buckets of
  fixed-size lists, about 0.5 MB, plus tournament slugs capped at 200 a
  minute bucket and 500 a quarter hour, with the rest added to "other": at
  worst 60,500 slug entries, about 4 MB, and only if that many different
  published tournaments are read in one day. A slug nothing has published
  under is never counted.

## Cleanup

Every server and load client was stopped by process id, and
`Get-NetTCPConnection -LocalPort 4004,4005 -State Listen` returned nothing
afterwards. `epmd`, started by the distribution used for the in-server
measurements, was stopped. The base checkout, databases, scripts and raw
results stayed in the session scratchpad; the digested assets
`mix assets.deploy` left in `priv/static/` were removed before committing.
