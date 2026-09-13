defmodule OpenResults.Federations.BEL.Sync do
  @moduledoc """
  Pulls the Belgian roster from the KBSB data platform and hands the
  reduced result to `OpenResults.Federations.BEL.Store`.

  A no-op when `OpenResults.Federations.BEL.Config.enabled?/0` is false - the
  scheduler still calls `run/0` on its timer, and this is where "off" turns
  into "do nothing" rather than every caller checking first.
  """

  require Logger

  alias OpenResults.Federations.BEL.{Api, Config, Store}

  @doc "Runs one sync now. Logged either way; never raises."
  @spec run() :: :ok
  def run do
    if Config.enabled?() do
      do_run()
    else
      :ok
    end
  end

  defp do_run do
    case Api.fetch_all() do
      {:ok, rows} ->
        case Store.put(rows) do
          :ok ->
            Logger.info("BEL roster sync: #{length(rows)} player(s)")
            :ok

          {:error, reason} ->
            message = "could not write the roster store: #{inspect(reason)}"
            Store.put_error(message)
            Logger.error("BEL roster sync FAILED: #{message}")
            :ok
        end

      {:error, reason} ->
        Store.put_error(reason)
        Logger.error("BEL roster sync FAILED: #{reason}")
        :ok
    end
  rescue
    error ->
      message = Exception.message(error)
      Store.put_error(message)
      Logger.error("BEL roster sync CRASHED: #{message}")
      :ok
  end
end
