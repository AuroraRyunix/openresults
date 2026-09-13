defmodule OpenResults.DiskSpaceTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import OpenResults.DiskSpaceHelpers

  alias OpenResults.DiskSpace

  describe "parse_df/1" do
    test "reads total and Available from POSIX output, in bytes" do
      output = """
      Filesystem     1024-blocks     Used Available Capacity Mounted on
      /dev/vda1         41152832 33000000   6000000      85% /
      """

      assert DiskSpace.parse_df(output) ==
               {:ok, %{total_bytes: 41_152_832 * 1024, available_bytes: 6_000_000 * 1024}}
    end

    test "survives spaces in the filesystem name and the mount point" do
      output =
        "Filesystem 1024-blocks Used Available Capacity Mounted on\n" <>
          "//nas/chess club    1000    400       600      40% /mnt/my share\n"

      assert {:ok, %{total_bytes: 1_024_000, available_bytes: 614_400}} =
               DiskSpace.parse_df(output)
    end

    test "anything else is an error, not a number" do
      for output <- ["", "df: /nope: No such file or directory\n", "Filesystem\nnonsense\n"] do
        assert {:error, _} = DiskSpace.parse_df(output)
      end
    end
  end

  describe "the reading" do
    test "below the floor is low; at or above it is not" do
      assert %{status: :low, free_percent: p} = disk_reads(free(9))
      assert_in_delta p, 9.0, 0.01
      assert DiskSpace.low?()

      assert %{status: :ok} = disk_reads(free(10))
      refute DiskSpace.low?()
    end

    test "the floor is read at check time, and 0 switches it off" do
      disk_reads(free(5))
      assert DiskSpace.low?()

      Application.put_env(:openresults, :min_free_disk_percent, 0)
      on_exit(fn -> Application.put_env(:openresults, :min_free_disk_percent, 10) end)
      refute DiskSpace.low?()
    end

    test "a failed, malformed or raising measurement is unknown, allows, and warns" do
      for answer <- [{:error, "no df on this system"}, {:ok, %{total_bytes: 0}}, :garbage] do
        capture_log(fn -> assert %{status: :unknown, error: _error} = disk_reads(answer) end)
        |> then(&assert(is_binary(&1)))

        refute DiskSpace.low?()
      end

      # Warned on the way INTO unknown, once - not on every measurement.
      disk_reads(free(50))
      Application.put_env(:openresults, :disk_space_reader, fn _ -> raise "boom" end)
      log = capture_log(fn -> assert %{status: :unknown, error: "boom"} = DiskSpace.refresh() end)
      assert log =~ "could not be measured"
      assert capture_log(fn -> DiskSpace.refresh() end) == ""
    end

    test "the real reader either measures the database's volume or says why not" do
      case DiskSpace.df(DiskSpace.path()) do
        {:ok, %{total_bytes: total, available_bytes: available}} ->
          assert total > 0 and available >= 0 and available <= total

        {:error, reason} ->
          assert is_binary(reason)
      end
    end
  end
end
