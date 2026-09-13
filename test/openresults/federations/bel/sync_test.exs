defmodule OpenResults.Federations.BEL.SyncTest do
  @moduledoc """
  Fetch, reduce and store, end to end - against a stubbed KBSB export.
  """
  use ExUnit.Case, async: false

  alias OpenResults.Federations.BEL.{Store, Sync}

  setup do
    path =
      Path.join(System.tmp_dir!(), "bel_sync_test_#{System.unique_integer([:positive])}.json")

    Application.put_env(:openresults, :bel_store_path, path)
    Application.put_env(:openresults, :bel_kbsb_api_url, "http://kbsb.example")
    Application.put_env(:openresults, :bel_kbsb_api_key, "s3cret")
    Application.put_env(:openresults, :bel_req_options, plug: {Req.Test, __MODULE__})
    Store.reset_for_test()

    on_exit(fn ->
      File.rm(path)
      Store.reset_for_test()
      Application.delete_env(:openresults, :bel_kbsb_api_url)
      Application.delete_env(:openresults, :bel_kbsb_api_key)
      Application.delete_env(:openresults, :bel_req_options)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  test "run/0 fetches, reduces and stores the roster" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "players" => [
          %{
            "national_id" => "1",
            "last_name" => "Peeters",
            "birthday" => "1990-01-01",
            "email" => "leaked@example.invalid"
          }
        ],
        "next_cursor" => nil
      })
    end)

    assert :ok = Sync.run()
    assert {:ok, %{count: 1, body: body}} = Store.current()
    decoded = Jason.decode!(body)
    refute String.contains?(body, "birthday")
    refute String.contains?(body, "leaked@example.invalid")
    assert [%{"national_id" => "1", "last_name" => "Peeters"}] = decoded["players"]
  end

  test "a fetch failure records last_error and leaves any previous roster untouched" do
    stub(fn conn ->
      Req.Test.json(conn, %{"players" => [%{"national_id" => "1"}], "next_cursor" => nil})
    end)

    Sync.run()
    assert {:ok, %{count: 1}} = Store.current()

    stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    Sync.run()

    assert {:ok, %{count: 1}} = Store.current()
    assert Store.stats().last_error
  end

  test "run/0 is a no-op when unconfigured" do
    Application.delete_env(:openresults, :bel_kbsb_api_key)
    assert :ok = Sync.run()
    assert Store.current() == :none
  end
end
