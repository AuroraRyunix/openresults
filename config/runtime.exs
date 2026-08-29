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
# Who may put these pages in an iframe - a CSP `frame-ancestors` source list.
# Default `*`: this site has no login and no session, so a framing page gains
# nothing it could not get by fetching the same URL itself, and a club showing
# its own tournament's standings on its front page is the ordinary case.
# Set to a space-separated origin list to restrict it, or `'none'` to switch
# embedding off. See `OpenResultsWeb.Framing`.
config :openresults,
       :public_frame_ancestors,
       System.get_env("PUBLIC_FRAME_ANCESTORS") || "*"

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

  config :openresults, OpenResults.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

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
