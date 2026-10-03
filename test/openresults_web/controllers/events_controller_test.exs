defmodule OpenResultsWeb.EventsControllerTest do
  @moduledoc """
  The tournament event stream: a publish reaches an open page as one
  `data:` line, and the page's script polls at once instead of at its next
  turn. See `OpenResultsWeb.EventsController`.

  A request runs the controller in the test process, so a message already
  in this process's mailbox when the stream subscribes is what the stream
  hears first - no timing involved. `config/test.exs` ends every stream after
  a few milliseconds so the request returns.

  Not async: one test lowers the stream ceiling for the whole node.
  """
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures, only: [unique_slug: 1]

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  setup do
    payload = SnapshotPayloads.swiss() |> put_in(["tournament", "slug"], unique_slug("events"))
    {:ok, _snapshot} = Snapshots.ingest(payload)

    {:ok, slug: payload["tournament"]["slug"]}
  end

  test "is an uncompressed event stream that tells the browser how soon to reconnect", %{
    conn: conn,
    slug: slug
  } do
    conn = get(conn, ~p"/t/#{slug}/events")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert get_resp_header(conn, "cache-control") == ["no-cache, no-transform"]
    assert conn.resp_body =~ ~r/\Aretry: \d+\n\n/
    refute conn.resp_body =~ "data:"
  end

  test "says 'changed' once for a burst of publishes", %{conn: conn, slug: slug} do
    for _ <- 1..3, do: send(self(), {:tournament_changed, slug})

    body = conn |> get(~p"/t/#{slug}/events") |> response(200)

    assert length(String.split(body, "data: changed\n\n")) == 2
  end

  test "hears nothing about another tournament", %{conn: conn, slug: slug} do
    send(self(), {:tournament_changed, "someone-else"})

    body = conn |> get(~p"/t/#{slug}/events") |> response(200)

    refute body =~ "data:"
  end

  test "leaves the connection unsubscribed when it ends", %{conn: conn, slug: slug} do
    get(conn, ~p"/t/#{slug}/events")

    OpenResults.TournamentEvents.changed(slug)

    refute_received {:tournament_changed, ^slug}
    assert Registry.count(OpenResults.EventStreams) == 0
  end

  test "is a plain 404 for a slug nothing published under", %{conn: conn} do
    conn = get(conn, ~p"/t/no-such-tournament/events")

    assert conn.status == 404
    assert conn.resp_body == "Not found\n"
  end

  test "answers 503 past its ceiling, so the page just keeps polling", %{conn: conn, slug: slug} do
    previous = Application.get_env(:openresults, OpenResultsWeb.EventsController)

    on_exit(fn ->
      Application.put_env(:openresults, OpenResultsWeb.EventsController, previous)
    end)

    Application.put_env(
      :openresults,
      OpenResultsWeb.EventsController,
      Keyword.put(previous, :max_streams, 0)
    )

    conn = get(conn, ~p"/t/#{slug}/events")

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  describe "the page" do
    test "names its stream on the region the refresher swaps", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}") |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query("#live-region") |> LazyHTML.attribute("data-events") ==
               ["/t/#{slug}/events"]
    end

    test "a 404 names none", %{conn: conn} do
      document =
        conn
        |> get(~p"/t/no-such-tournament")
        |> html_response(404)
        |> LazyHTML.from_document()

      assert document |> LazyHTML.query("#live-region[data-events]") |> Enum.empty?()
    end
  end
end
