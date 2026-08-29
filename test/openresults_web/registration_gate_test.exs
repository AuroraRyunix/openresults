defmodule OpenResultsWeb.RegistrationGateTest do
  @moduledoc """
  The arbiter's `registration_open` switch, which only reaches this site by
  riding along in the snapshot.

  Before 2026-08-29 the arbiter's own app served an entry form and enforced
  this flag itself, so this site accepted entries for every published
  tournament without asking. That app's form is gone; this is the only one,
  and the flag now has to be honoured here or it does not exist anywhere.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.RateLimit
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  setup do
    RateLimit.reset()
    :ok
  end

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp with_registration(payload, value) do
    put_in(payload, ["tournament", "registration_open"], value)
  end

  defp without_registration(payload) do
    update_in(payload, ["tournament"], &Map.delete(&1, "registration_open"))
  end

  defp entry do
    %{"name" => "De Vos, Ilse", "email" => "ilse.de.vos@example.invalid", "federation" => "bel"}
  end

  describe "entries closed" do
    setup do
      {:ok, slug: SnapshotPayloads.swiss() |> with_registration(false) |> publish()}
    end

    test "the form refuses to render", %{conn: conn, slug: slug} do
      conn = get(conn, ~p"/t/#{slug}/register")

      assert html_response(conn, 403) =~ "Entries are closed"
    end

    test "a post is refused and stores nothing", %{conn: conn, slug: slug} do
      conn = post(conn, ~p"/t/#{slug}/register", registration: entry())

      assert html_response(conn, 403) =~ "Entries are closed"
      assert OpenResults.Registrations.list_for_tournament(slug) == []
    end

    test "and the tournament page stops advertising it", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)

      refute html =~ "Enter this tournament"
      # The tournament itself is still perfectly readable - closing entries is
      # not taking the event down.
      assert html =~ "Standings"
    end

    test "the closed page points back at the tournament, not at a 404", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/register") |> html_response(403)

      assert html =~ ~s|href="/t/#{slug}"|
    end
  end

  describe "entries open" do
    setup do
      {:ok, slug: SnapshotPayloads.swiss() |> with_registration(true) |> publish()}
    end

    test "the form renders and the tournament page links to it", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}/register") |> html_response(200) =~ "registration-form"
      assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "Enter this tournament"
    end
  end

  describe "a payload that predates the field" do
    test "is treated as open", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> without_registration() |> publish()

      # The load-bearing default. Every snapshot published before 2026-08-29
      # is silent here, and this server accepted entries for all of them - so
      # reading silence as "closed" would have shut every already-published
      # tournament's form the moment this deployed, with nothing in either
      # app to explain why.
      assert conn |> get(~p"/t/#{slug}/register") |> html_response(200) =~ "registration-form"
    end

    test "and an explicit true is still open, not merely 'not false'", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> with_registration(true) |> publish()

      assert conn |> get(~p"/t/#{slug}/register") |> html_response(200) =~ "registration-form"
    end
  end

  describe "closing and re-opening" do
    test "a later snapshot re-opens a form an earlier one closed", %{conn: conn} do
      payload = SnapshotPayloads.swiss()
      slug = payload |> with_registration(false) |> publish()

      assert conn |> get(~p"/t/#{slug}/register") |> html_response(403)

      # The arbiter changed their mind. Nothing here needs to know that
      # happened - the newest snapshot simply says something different.
      _ = payload |> with_registration(true) |> publish()

      assert conn |> get(~p"/t/#{slug}/register") |> html_response(200) =~ "registration-form"
    end
  end
end
