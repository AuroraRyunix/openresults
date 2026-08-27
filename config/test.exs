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
  database: Path.expand("../openresults_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

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
