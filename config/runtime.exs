import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/openresults start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :openresults, OpenResultsWeb.Endpoint, server: true
end

# Outside the prod block on purpose, so a dev or staging box can point a real
# OpenPairings at it by exporting one variable. Absent, whatever the
# environment's config file set stands - and in prod that is nil, so publishing
# is refused until someone sets this. Refusing to ingest is a better failure
# than refusing to boot: the read side keeps serving the tournaments already
# published while the token is sorted out.
if ingest_token = System.get_env("OPENRESULTS_INGEST_TOKEN") do
  config :openresults, :ingest_token, ingest_token
end

# Lending the entry form a search of the arbiter's FIDE list - see
# `OpenResults.FideLookup`. Both must be set or the feature is simply absent
# and the form asks people to type their own details, which is what it did
# before this existed.
#
# On a deployment where both applications share a box this is
# `http://localhost:4001` and the request never leaves the machine. There is
# no sensible value for a results site that cannot reach an arbiter, which is
# why it is opt-in rather than defaulted.
#
# The token is the arbiter's own ingest token, because it is the same pair of
# machines and a second secret would be a second thing to rotate.
# Backups - see `OpenResults.Backup`. Nothing in this database is
# reproducible: the snapshots are a published record, `/history?at=` answers a
# question that cannot be recomputed, the queue holds entries nobody has
# reviewed, and the keys decide who may withdraw a tournament.
#
# BACKUP_DIR defaults to a `backups/` directory beside the database.
# OPENRESULTS_BACKUP_PASSPHRASE encrypts them, which is worth doing: the
# registration queue carries the email addresses people gave the entry form.
if backup_dir = System.get_env("BACKUP_DIR") do
  config :openresults, :backup_dir, backup_dir
end

if passphrase = System.get_env("OPENRESULTS_BACKUP_PASSPHRASE") do
  config :openresults, :backup_passphrase, passphrase
end

if keep = System.get_env("BACKUP_RETENTION") do
  config :openresults, :backup_retention, String.to_integer(keep)
end

# Who may put these pages in an iframe - a CSP `frame-ancestors` source list.
# Default `*`: this site has no login and no session, so a framing page gains
# nothing it could not get by fetching the same URL itself, and a club showing
# its own tournament's standings on its front page is the ordinary case.
# Set to a space-separated origin list to restrict it, or `'none'` to switch
# embedding off. See `OpenResultsWeb.Framing`.
config :openresults,
       :public_frame_ancestors,
       System.get_env("PUBLIC_FRAME_ANCESTORS") || "*"

# Public publishing - `docs/public-publishing.md`. Nothing here is required.
# Only the exact value `enabled` switches the feature on: a typo leaves it off,
# which is the safe direction for a switch that opens the server to anybody.
if public_publishing = System.get_env("OPENRESULTS_PUBLIC_PUBLISHING") do
  config :openresults, :public_publishing, public_publishing == "enabled"
end

if operator_name = System.get_env("OPENRESULTS_OPERATOR_NAME") do
  config :openresults, :operator_name, operator_name
end

if terms_url = System.get_env("OPENRESULTS_TERMS_URL") do
  config :openresults, :terms_url, terms_url
end

for {variable, key} <- [
      {"OPENRESULTS_REGISTRATIONS_PER_ADDRESS", :registrations_per_address},
      {"OPENRESULTS_REGISTRATIONS_PER_DAY", :registrations_per_day},
      {"OPENRESULTS_INSTALLATION_PUBLISHES_PER_MINUTE", :installation_publishes_per_minute},
      {"OPENRESULTS_INSTALLATION_MAX_TOURNAMENTS", :installation_max_tournaments},
      {"OPENRESULTS_INSTALLATION_MAX_SNAPSHOT_BYTES", :installation_max_snapshot_bytes}
    ],
    value = System.get_env(variable) do
  # Raises at boot on something that is not a number, like BACKUP_RETENTION
  # above: a limit silently read as something else is worse than a loud start.
  config :openresults, key, String.to_integer(value)
end

if lookup = System.get_env("FIDE_LOOKUP_ENDPOINT") do
  config :openresults, :fide_lookup_endpoint, lookup
end

if lookup_token = System.get_env("FIDE_LOOKUP_TOKEN") do
  config :openresults, :fide_lookup_token, lookup_token
end

config :openresults, OpenResultsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :openresults, OpenResultsWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/openresults_web/router\.ex$"E,
        ~r"lib/openresults_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/openresults/openresults.db
      """

  # POOL_SIZE default, raised from 5 to 10 after the 2026-09-12 load test
  # (`docs/load-test-2026-09-12.md`). That test found `pool_size: 5`
  # exhausted between 200 and 400 concurrent readers on a 2 vCPU box -
  # `DBConnection.ConnectionError`, queue waits up to 2.7s - but the actual
  # cause was `Plugs.Revalidate` running a real query on EVERY request,
  # including a bare `304`. That is fixed separately (see
  # `OpenResults.Snapshots.LatestIdCache`): a request that only needs "is my
  # copy current" now costs an ETS lookup, not a connection checkout, so the
  # pool is no longer on the hot path for ordinary read traffic at all.
  #
  # This is not "therefore leave it at 5". What is left on the pool once the
  # hot path is gone is a burst of genuine cache misses (many tournaments'
  # ids all cold at once - a restart, mid-event) plus actual writes
  # (publishes, registrations, backups), and those deserve headroom without
  # over-provisioning a small box: SQLite has exactly one writer regardless
  # of pool size, so a bigger pool buys more concurrent READERS in flight,
  # not more write throughput, and a 2 vCPU box gets little from a pool far
  # past its core count. 10 - double the old default, five times the box's
  # vCPUs - covers a multi-tournament cold-cache burst comfortably while
  # staying a small, cheap number for a read-mostly app that (with the fix
  # above) spends almost none of its request volume on the database at all.
  config :openresults, OpenResults.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :openresults, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :openresults, OpenResultsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :openresults, OpenResultsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :openresults, OpenResultsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
