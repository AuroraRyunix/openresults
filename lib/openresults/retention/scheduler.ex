defmodule OpenResults.Retention.Scheduler do
  @moduledoc """
  Runs `OpenResults.Retention` once a day.

  The same shape as `OpenResults.Backup.Scheduler`, for the same reasons: an
  interval since the last run rather than a time of day, a first run shortly
  after boot, and a failure logged rather than raised - retention that could
  not run today is a problem for the operator, not a reason to take the site
  down.
  """

  use GenServer

  alias OpenResults.Retention

  require Logger

  @first_run :timer.minutes(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:openresults, :retention_interval, :timer.hours(24))
      end)

    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  # `:disabled` starts the process without a timer - the test environment.
  @impl true
  def handle_continue(:schedule, %{interval: :disabled} = state), do: {:noreply, state}

  def handle_continue(:schedule, state) do
    Process.send_after(self(), :run, @first_run)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run, state) do
    run()
    Process.send_after(self(), :run, state.interval)
    {:noreply, state}
  end

  defp run do
    result = Retention.run()

    Logger.info(
      "Retention: #{result.addresses_nulled} address(es) forgotten, " <>
        "#{length(result.slugs_released)} unpublished slug(s) released, " <>
        "#{result.blocks_removed} expired block(s) removed"
    )
  rescue
    error -> Logger.error("Retention FAILED: #{Exception.message(error)}")
  end
end
