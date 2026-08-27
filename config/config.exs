# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :openresults,
  ecto_repos: [OpenResults.Repo],
  generators: [timestamp_type: :utc_datetime]

# The bearer token an arbiter's machine publishes with. Deliberately nil here:
# a default that works is a default that reaches production. Each environment
# supplies its own, and config/runtime.exs reads OPENRESULTS_INGEST_TOKEN so a
# release never carries the real one in its build. Unset means every publish
# is refused, which is the right way for this to fail.
config :openresults, :ingest_token, nil

# Configure the endpoint
config :openresults, OpenResultsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OpenResultsWeb.ErrorHTML, json: OpenResultsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: OpenResults.PubSub,
  live_view: [signing_salt: "cwbu1VZz"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  openresults: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  openresults: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Windows cannot create the symlink LiveView wants for colocated assets
# without an elevated terminal, and this project has no colocated hooks to
# import from node_modules. The warning is noise on every compile.
config :phoenix_live_view,
  colocated_assets: [disable_symlink_warning: true]
