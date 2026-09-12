import Config

# The token the ingest tests present. Set here rather than in each test so a
# test that forgets to authenticate fails for that reason and not because the
# server had no token configured either.
config :openresults, :ingest_token, "test-ingest-token"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :openresults, OpenResults.Repo,
  database: Path.expand("../openresults_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  # One connection, so the pool cannot contend with itself. SQLite's default
  # (WAL, from ecto_sqlite3) lets readers and a writer coexist, but it does
  # NOT let a connection's read survive a concurrent commit: `Snapshots.store/3`
  # and `Registrations.room_for_one_more/2` both read (has this already been
  # published? is the queue full?) and then write, inside the one transaction
  # the Sandbox holds open for the whole test. If any other pooled connection
  # commits between that read and that write, this connection's write is
  # rejected outright - reproduced with two raw connections: a busy_timeout of
  # 30000ms did not make it wait, the write failed in under 5ms every time,
  # because a stale WAL read snapshot cannot be promoted to a writer no matter
  # how long the caller is willing to wait; only a fresh transaction can. With
  # `pool_size: 5` and dozens of `SnapshotsTest`/`RegistrationsTest` cases all
  # doing exactly that read-then-write, two of them landing on different
  # connections during the same span was routine, not rare - reliably ~1 run
  # in 2 by the time the async controller test files added enough concurrent
  # writers. Raising `busy_timeout` alone therefore barely helped (it targets
  # a lock a connection is willing to wait out, and this one is not that);
  # forcing `default_transaction_mode: :immediate` made it worse, because it
  # makes every transaction - reads included - queue for the same single
  # write slot across all 5 connections at once. Serialising the pool instead
  # removes the second connection a commit could ever come from. Tests still
  # declare `async: true` and DBConnection queues them on the one connection,
  # which costs the suite nothing worth trading this away for (~3.3s either
  # way, locally).
  pool_size: 1,
  pool: Ecto.Adapters.SQL.Sandbox,
  # Kept explicit rather than left to ecto_sqlite3's defaults, which already
  # match these: a backstop for whatever contention a single connection can
  # still see (checkin/checkout overlap, or `OpenResults.BackupTest`'s raw,
  # unsandboxed connection onto the very same file for its `VACUUM INTO`).
  busy_timeout: 30_000,
  journal_mode: :wal

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :openresults, OpenResultsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Hs4X1UdFiDVp/0nABZuXHWdB5NMCojPBkJIbbWnSqN7STA7wLJH+Itnxj2CngG8O",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :openresults, :backup_interval, :disabled

# On in test, so the suite exercises the feature; the tests that prove the
# environment gate switch it off themselves (and are not async).
config :openresults, :public_publishing, true
config :openresults, :retention_interval, :disabled
