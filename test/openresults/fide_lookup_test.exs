defmodule OpenResults.FideLookupTest do
  @moduledoc """
  Lending the entry form a search of the arbiter's FIDE list.

  The old local form let a player find themselves on the list; the form moved
  here and the list did not, so people were typing FIDE IDs from memory. The
  list still lives on the arbiter's machine, and this asks it.

  Everything here is about failing quietly. The form works without a search -
  every field it fills can be typed - so an unreachable machine, a refused
  token or a garbled answer must all produce "no matches" rather than an
  error about somebody else's server, which the person typing their name can
  do nothing with.
  """
  use OpenResults.DataCase, async: false

  alias OpenResults.FideLookup

  @endpoint_url "http://arbiter.example"

  setup do
    Application.put_env(:openresults, :fide_lookup_endpoint, @endpoint_url)
    Application.put_env(:openresults, :fide_lookup_token, "s3cret")

    Application.put_env(:openresults, :fide_lookup_req_options,
      plug: {Req.Test, OpenResults.FideLookupTest}
    )

    on_exit(fn ->
      Application.delete_env(:openresults, :fide_lookup_endpoint)
      Application.delete_env(:openresults, :fide_lookup_token)
      Application.delete_env(:openresults, :fide_lookup_req_options)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(OpenResults.FideLookupTest, fun)

  defp answering(players) do
    stub(fn conn -> Req.Test.json(conn, %{"players" => players}) end)
  end

  defp ilse do
    %{
      "fide_id" => 2_503_014,
      "name" => "De Vos, Ilse",
      "title" => "WFM",
      "federation" => "BEL",
      "birth_year" => 1994,
      "rating" => 1804
    }
  end

  describe "configuration" do
    test "both halves are required" do
      assert FideLookup.configured?()

      Application.delete_env(:openresults, :fide_lookup_token)
      refute FideLookup.configured?()
    end

    test "an unconfigured site searches nothing and asks nobody" do
      Application.delete_env(:openresults, :fide_lookup_endpoint)
      stub(fn _conn -> flunk("nothing should have been requested") end)

      assert FideLookup.search("De Vos") == []
    end
  end

  describe "searching" do
    test "returns the arbiter's candidates" do
      answering([ilse()])

      assert [player] = FideLookup.search("De Vos")
      assert player["name"] == "De Vos, Ilse"
      assert player["fide_id"] == 2_503_014
    end

    test "carries the token and the query" do
      test_pid = self()

      stub(fn conn ->
        send(
          test_pid,
          {:asked, conn.request_path, conn.query_string,
           Plug.Conn.get_req_header(conn, "authorization")}
        )

        Req.Test.json(conn, %{"players" => []})
      end)

      FideLookup.search("De Vos", "rapid")

      assert_receive {:asked, path, query, ["Bearer s3cret"]}
      assert path == "/internal/fide/search"
      assert query =~ "q=De+Vos"

      # The tournament's own tempo, so a rapid event gets rapid ratings. A
      # player entered at their standard rating in a blitz tournament is
      # seeded wrong.
      assert query =~ "tempo=rapid"
    end

    test "a query too short to mean anything asks nobody" do
      stub(fn _conn -> flunk("nothing should have been requested") end)

      assert FideLookup.search("D") == []
      assert FideLookup.search("") == []
      assert FideLookup.search("   ") == []
    end
  end

  describe "when the arbiter's machine cannot answer" do
    test "a refused token is no matches, not an error" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"})) end)

      assert FideLookup.search("De Vos") == []
    end

    test "a machine that is asleep is no matches" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert FideLookup.search("De Vos") == []
    end

    test "an answer in a shape nobody expected is no matches" do
      # A results site is not the place to discover that an arbiter is running
      # a build that answers differently.
      for body <- [%{"players" => "nope"}, %{}, %{"players" => [1, 2, 3]}] do
        stub(fn conn -> Req.Test.json(conn, body) end)

        assert is_list(FideLookup.search("De Vos"))
      end
    end

    test "and a slow one does not hold the page open forever" do
      # The timeout is the point: a person typing their name should not wait
      # on a laptop that has gone to sleep mid-round.
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert FideLookup.search("De Vos") == []
    end
  end
end
