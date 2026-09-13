defmodule OpenResults.Federations.BEL.StoreTest do
  @moduledoc """
  The atomic write (temp file + rename) and the served copy it swaps in.
  """
  use ExUnit.Case, async: false

  alias OpenResults.Federations.BEL.Store

  setup do
    path =
      Path.join(System.tmp_dir!(), "bel_store_test_#{System.unique_integer([:positive])}.json")

    previous = Application.get_env(:openresults, :bel_store_path)
    Application.put_env(:openresults, :bel_store_path, path)

    Store.reset_for_test()

    on_exit(fn ->
      File.rm(path)
      Store.reset_for_test()
      if previous, do: Application.put_env(:openresults, :bel_store_path, previous)
    end)

    :ok
  end

  test "put/1 writes the file, and current/0 serves it back" do
    rows = [%{national_id: "1", last_name: "Solo"}]
    assert :ok = Store.put(rows)

    assert {:ok, %{count: 1, body: body, gzip: gzip, etag: etag}} = Store.current()
    assert %{"count" => 1, "players" => [%{"national_id" => "1"}]} = Jason.decode!(body)
    assert :zlib.gunzip(gzip) == body
    assert String.starts_with?(etag, ~s("))

    assert File.exists?(Store.path())
    assert Jason.decode!(File.read!(Store.path()))["count"] == 1
  end

  test "no temp file is left behind after a successful write" do
    Store.put([%{national_id: "1"}])
    dir = Path.dirname(Store.path())
    refute Enum.any?(File.ls!(dir), &String.contains?(&1, ".tmp-"))
  end

  test "put_error/1 is visible in stats/0 and does not touch the served roster" do
    Store.put([%{national_id: "1"}])
    :ok = Store.put_error("boom")

    stats = Store.stats()
    assert stats.last_error == "boom"
    assert stats.count == 1

    assert {:ok, _} = Store.current()
  end

  test "a later successful put/1 clears the previous error" do
    Store.put_error("boom")
    Store.put([%{national_id: "1"}])
    assert Store.stats().last_error == nil
  end

  test "current/0 is :none before anything has ever synced" do
    assert Store.current() == :none
    assert Store.stats() == %{updated_at: nil, count: 0, last_error: nil, last_error_at: nil}
  end
end
