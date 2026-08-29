defmodule OpenResultsWeb.FramingTest do
  @moduledoc """
  A club site may put these pages in an iframe.

  This test exists because the feature was reported as working when it never
  had been. The arbiter's app served three embeddable pages behind a careful
  per-route argument; they moved here on 2026-08-29, the argument moved with
  them, and the header did not - Phoenix's own
  `frame-ancestors 'self'` blocked every embed from the first day. Nothing
  caught it, because nothing looked at a response.

  So this looks at responses. The check that matters is not "is the plug
  wired" but "does the header that actually goes out permit framing".
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  setup do
    swiss = SnapshotPayloads.swiss()
    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, slug: swiss["tournament"]["slug"]}
  end

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  describe "every page a club would embed" do
    test "permits framing", %{conn: conn, slug: slug} do
      for path <- ["/", "/t/#{slug}", "/t/#{slug}/round/1", "/t/#{slug}/player/1"] do
        policy = conn |> get(path) |> csp()

        refute policy =~ "frame-ancestors 'self'", "#{path} still refuses framing"
        assert policy =~ "frame-ancestors *", "#{path} has no frame-ancestors at all"
      end
    end

    test "including the entry form", %{conn: conn, slug: slug} do
      # It writes, which is why the arbiter's app argued about it for a
      # paragraph. The argument holds and is shorter here: the form takes no
      # authority from the visitor because there is none to take, and what
      # they type reaches this server either way.
      policy = conn |> get(~p"/t/#{slug}/register") |> csp()

      assert policy =~ "frame-ancestors *"
    end

    test "and a not-found page, so a mistyped embed shows the site's own 404", %{conn: conn} do
      policy = conn |> get(~p"/t/no-such-tournament") |> csp()

      assert policy =~ "frame-ancestors *"
    end
  end

  describe "what is left alone" do
    test "the rest of the policy is untouched", %{conn: conn} do
      policy = conn |> get(~p"/") |> csp()

      # Only the one directive changes, so this cannot loosen anything else
      # by accident.
      assert policy =~ "base-uri 'self'"
    end

    test "no x-frame-options contradicts it", %{conn: conn} do
      # Phoenix does not set one, but a reverse proxy might, and the older
      # header has no syntax for "these origins" - a stray SAMEORIGIN would
      # silently win in the browsers that still prefer it.
      assert get_resp_header(get(conn, ~p"/"), "x-frame-options") == []
    end
  end

  describe "and it can be shut off without touching the router" do
    test "an origin list restricts it", %{conn: conn} do
      Application.put_env(:openresults, :public_frame_ancestors, "https://club.example")
      on_exit(fn -> Application.put_env(:openresults, :public_frame_ancestors, "*") end)

      assert conn |> get(~p"/") |> csp() =~ "frame-ancestors https://club.example"
    end

    test "and an empty value means none rather than everything", %{conn: conn} do
      # The dangerous typo. An empty environment variable producing
      # `frame-ancestors ` with nothing after it would be a malformed
      # directive, and browsers disagree about what to do with one.
      Application.put_env(:openresults, :public_frame_ancestors, "  ")
      on_exit(fn -> Application.put_env(:openresults, :public_frame_ancestors, "*") end)

      assert conn |> get(~p"/") |> csp() =~ "frame-ancestors 'none'"
    end
  end
end
