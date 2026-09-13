defmodule OpenResults.DiskSpaceHelpers do
  @moduledoc """
  Injects a free-space reading into `OpenResults.DiskSpace` for a test and
  puts the test environment's "not measured" back afterwards.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias OpenResults.DiskSpace

  @doc "Makes the next measurement `answer` (a reader result), and measures."
  def disk_reads(answer) do
    Application.put_env(:openresults, :disk_space_reader, fn _dir -> answer end)

    on_exit(fn ->
      Application.put_env(:openresults, :disk_space_reader, {DiskSpace, :unmeasured})
      DiskSpace.refresh()
    end)

    DiskSpace.refresh()
  end

  @doc "A volume of 100 GiB with `percent` of it available."
  def free(percent) do
    total = 100 * 1024 * 1024 * 1024
    {:ok, %{total_bytes: total, available_bytes: div(total * percent, 100)}}
  end
end
