defmodule OpenResults.Federations.BEL.Scheduler do
  @moduledoc """
  Runs `OpenResults.Federations.BEL.Sync` once a day, plus once at boot when
  the stored roster is missing or older than a day - the same shape as
  `OpenResults.Retention.Scheduler` and `OpenResults.Backup.Scheduler`, and
  for the same reasons: an interval since the last run rather than a time of
  day, and a failure logged rather than raised.

  A no-op run (the feature not configured) costs nothing beyond the timer.
  """

  use GenServer

  alias OpenResults.Federations.BEL.{Store, Sync}

  require Logger

  # Long enough that a boot storm of several processes starting at once does
  # not all hit the KBSB API in the same second; short enough that "the
  # roster was stale at boot" is fixed well within the hour.
  @boot_check_delay :timer.seconds(30)
  @stale_after :timer.hours(24)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:openresults, :bel_sync_interval, :timer.hours(24))
      end)

    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  # `:disabled` starts the process without a timer - the test environment.
  @impl true
  def handle_continue(:schedule, %{interval: :disabled} = state), do: {:noreply, state}

  def handle_continue(:schedule, state) do
    Process.send_after(self(), :maybe_run_at_boot, @boot_check_delay)
    Process.send_after(self(), :run, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:maybe_run_at_boot, state) do
    if stale?(), do: run()
    {:noreply, state}
  end

  def handle_info(:run, state) do
    run()
    Process.send_after(self(), :run, state.interval)
    {:noreply, state}
  end

  defp stale? do
    case Store.current() do
      :none ->
        true

      {:ok, %{updated_at: at}} ->
        DateTime.diff(DateTime.utc_now(), at, :millisecond) > @stale_after
    end
  end

  defp run do
    Sync.run()
  rescue
    error -> Logger.error("BEL roster scheduler: sync raised #{Exception.message(error)}")
  end
end
