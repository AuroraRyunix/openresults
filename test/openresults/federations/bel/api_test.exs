defmodule OpenResults.Federations.BEL.ApiTest do
  @moduledoc """
  The cursor-paginated walk against the KBSB data platform, stubbed with
  `Req.Test` - no real network, mirrors `PairingsEngine.Federations.BEL.ApiTest`'s
  approach against the same upstream endpoint.
  """
  use ExUnit.Case, async: false

  alias OpenResults.Federations.BEL.Api

  setup do
    Application.put_env(:openresults, :bel_kbsb_api_url, "http://kbsb.example")
    Application.put_env(:openresults, :bel_kbsb_api_key, "s3cret")
    Application.put_env(:openresults, :bel_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:openresults, :bel_kbsb_api_url)
      Application.delete_env(:openresults, :bel_kbsb_api_key)
      Application.delete_env(:openresults, :bel_req_options)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp player(id), do: %{"national_id" => id, "last_name" => "Player#{id}"}

  test "walks pages until next_cursor is nil, and every row is already reduced" do
    stub(fn conn ->
      case conn.params["cursor"] do
        nil -> Req.Test.json(conn, %{"players" => [player(1), player(2)], "next_cursor" => 2})
        "2" -> Req.Test.json(conn, %{"players" => [player(3)], "next_cursor" => nil})
      end
    end)

    assert {:ok, rows} = Api.fetch_all()
    assert Enum.map(rows, & &1.national_id) == ["1", "2", "3"]
    # Reduced already - no birthday/died/affiliated key exists on a row.
    assert Enum.all?(
             rows,
             &(Map.keys(&1) |> Enum.sort() ==
                 Enum.sort(OpenResults.Federations.BEL.Fields.allowed()))
           )
  end

  test "reports the KBSB API key header sent" do
    stub(fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["s3cret"]
      Req.Test.json(conn, %{"players" => [], "next_cursor" => nil})
    end)

    assert {:ok, []} = Api.fetch_all()
  end

  test "not configured" do
    Application.delete_env(:openresults, :bel_kbsb_api_key)
    assert {:error, _} = Api.fetch_all()
  end

  test "a non-200 fails the walk" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, _} = Api.fetch_all()
  end

  test "retries a transient failure before giving up" do
    Application.put_env(:openresults, :bel_retries, 2)
    Application.put_env(:openresults, :bel_retry_backoff_ms, [0, 0])
    on_exit(fn -> Application.delete_env(:openresults, :bel_retries) end)

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    stub(fn conn ->
      attempt = Agent.get_and_update(agent, &{&1, &1 + 1})

      if attempt < 2 do
        Plug.Conn.send_resp(conn, 503, "try later")
      else
        Req.Test.json(conn, %{"players" => [player(1)], "next_cursor" => nil})
      end
    end)

    assert {:ok, [%{national_id: "1"}]} = Api.fetch_all()
  end

  test "a cursor that fails to advance is an error, not an infinite loop" do
    stub(fn conn ->
      Req.Test.json(conn, %{"players" => [player(1)], "next_cursor" => 0})
    end)

    assert {:error, message} = Api.fetch_all()
    assert message =~ "did not advance"
  end
end
