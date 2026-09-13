defmodule OpenResults.Backup.Scheduler do
  @moduledoc """
  Writes a backup on a timer, and prunes the old ones.

  The same shape as the arbiter app's, and the same reasoning: an interval
  since the last run rather than a time of day, because a server that reboots
  at 01:59 would skip a 02:00 job and never say so; a first run a few minutes
  after boot, because a machine that has just restarted is exactly when there
  is most likely to be nothing on disk; and failures logged rather than raised,
  because a full disk is a problem for the operator and not a reason to take
  down the site the backups protect.

  That first run only happens when the newest backup is at least an interval
  old. Until 2026-09-13 every boot wrote one and retention counted files, so
  a day of deploys spent a day of retention per deploy (restore drill, finding
  12). Retention is an age now (`OpenResults.Backup.prune/1`), and a boot that
  finds a recent backup schedules the next for when that one comes due - one
  a day however often the site restarts, so a reboot loop cannot fill the disk
  with whole copies of the database that an age rule would keep.
  """
  use GenServer

  alias OpenResults.Backup

  require Logger

  @interval :timer.hours(24)
  @first_run :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one now, for tests and for a manual run."
  def run_now, do: GenServer.call(__MODULE__, :run, 120_000)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:openresults, :backup_interval, @interval)
      end)

    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  # `:disabled` starts the process without a timer, which is what the test
  # environment wants: this one copies the whole database to disk.
  @impl true
  def handle_continue(:schedule, %{interval: :disabled} = state), do: {:noreply, state}

  def handle_continue(:schedule, state) do
    Process.send_after(self(), :run, first_delay(Backup.newest_age_ms(), state.interval))
    {:noreply, state}
  end

  @doc false
  # How long after boot the first run is: a few minutes when there is no
  # backup or the newest is at least an interval old, otherwise when the
  # newest comes due - never sooner than the few minutes, never later than an
  # interval. Public for the test, which has no clock to wait on.
  def first_delay(nil, _interval), do: @first_run
  def first_delay(age_ms, interval), do: min(max(interval - age_ms, @first_run), interval)

  @impl true
  def handle_info(:run, state) do
    run()
    Process.send_after(self(), :run, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:run, _from, state), do: {:reply, run(), state}

  defp run do
    case Backup.create() do
      {:ok, path} ->
        pruned = Backup.prune()
        # What no remaining backup can bring back is no longer worth keeping in
        # the moderation journal - see `OpenResults.ModerationJournal.trim/1`.
        OpenResults.ModerationJournal.trim()

        Logger.info(
          "Backup written: #{Path.basename(path)}" <>
            if(pruned > 0, do: ", #{pruned} old one(s) removed", else: "")
        )

        {:ok, path}

      {:error, reason} ->
        Logger.error("Backup FAILED: #{reason}")
        {:error, reason}
    end
  end
end
