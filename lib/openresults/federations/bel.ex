defmodule OpenResults.Federations.BEL do
  @moduledoc """
  The Belgian (KBSB/FRBE) roster relay's small public face - what the admin
  panel shows. The actual work is `OpenResults.Federations.BEL.{Config, Api,
  Fields, Store, Sync, Scheduler}`; this just gathers their answers into one
  read-only view. docs/federations-bel.md is the contract.
  """

  alias OpenResults.Federations.BEL.{Config, Store}

  @doc """
  What `/admin/settings` shows, read-only: whether the relay is configured,
  and - if it is - the last successful sync's time and player count, plus
  the last error, if any.
  """
  @spec admin_stats() :: map()
  def admin_stats do
    Map.put(Store.stats(), :configured?, Config.enabled?())
  end
end
