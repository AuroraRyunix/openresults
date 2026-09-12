defmodule OpenResults.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The value every page's ETag is keyed with. Drawn here rather than
    # lazily, so it is one value for the whole node from before the first
    # request instead of whichever of two racing requests got there first -
    # and a tag that changed under a reader would answer 200 to every
    # revalidation. See `OpenResultsWeb.Plugs.Revalidate`.
    OpenResultsWeb.Plugs.Revalidate.new_secret()

    children = [
      OpenResultsWeb.Telemetry,
      OpenResults.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:openresults, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:openresults, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: OpenResults.PubSub},
      # Owns the ETS table behind the entry form's rate limit. Before the
      # endpoint, so the table exists before anything can be posted at it.
      OpenResults.RateLimit,
      # Owns the ETS table behind `Snapshots.latest_id/1`. Before the
      # endpoint for the same reason as the rate limiter above: the table
      # must exist before the first request, not be created lazily by
      # whichever request happens to arrive first. See
      # `OpenResults.Snapshots.LatestIdCache`.
      OpenResults.Snapshots.LatestIdCache,
      # Own the ETS tables behind the decoded-snapshot cache and the
      # rendered-page cache, for the same reason and by the same fix as
      # LatestIdCache just above - see `OpenResults.Snapshots.BodyCache`'s
      # moduledoc for the load-test-confirmed failure this closes: left
      # lazy, either table's lifetime was tied to whichever connection
      # process happened to create it, and that process exiting (an
      # ordinary event under load) silently reopened the exact DB-pool
      # exhaustion LatestIdCache exists to prevent.
      OpenResults.Snapshots.BodyCache,
      OpenResultsWeb.Plugs.Revalidate.PageTable,
      # Start to serve requests, typically the last entry
      OpenResults.Backup.Scheduler,
      OpenResultsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OpenResults.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpenResultsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
