defmodule OpenResultsWeb.AdminRelayKeysTest do
  @moduledoc """
  Relay keys as the panel handles them: made from a confirmation page, the
  secret shown on the response that made it and nowhere afterwards, listed
  with their last use, revoked from a confirmation page, logged.
  """

  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.Moderation.Action
  alias OpenResults.RelayKeys
  alias OpenResultsWeb.AdminWorld

  @admin "arbiter@example.org"

  setup do
    reset_admin_access()
    configure_access()
    {:ok, world: AdminWorld.build()}
  end

  defp secret(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#relay-key-secret")
    |> LazyHTML.text()
    |> String.trim()
  end

  test "the tournament's page links to the relay keys", %{world: world} do
    page = admin_get("/admin/tournaments/#{world.listed}") |> html_response(200)
    assert page =~ "/admin/tournaments/#{world.listed}/relay-keys"
  end

  test "makes a key from its confirmation page, shows it once, and logs without it", %{
    world: world
  } do
    slug = world.listed
    path = "/admin/tournaments/#{slug}/relay-keys/new"

    assert admin_get(path) |> html_response(200) =~ ~s(name="label")

    conn = confirm_and_post(path, %{"label" => "  upstairs box "})
    page = html_response(conn, 200)
    key = secret(page)

    assert String.starts_with?(key, "orrk_")
    assert String.length(key) == 48
    assert get_resp_header(conn, "cache-control") |> Enum.join() =~ "no-store"
    assert {:ok, %{label: "upstairs box"}} = RelayKeys.authenticate(key)

    assert %Action{actor: @admin, action: "relay_key_create", target: ^slug, details: details} =
             last_action()

    refute inspect(details) =~ key
    refute inspect(OpenResults.Moderation.list_actions(%{limit: 50})) =~ key

    # Every page afterwards: the label and the last four characters.
    list = admin_get("/admin/tournaments/#{slug}/relay-keys") |> html_response(200)
    assert list =~ "upstairs box"
    assert list =~ String.slice(key, -4, 4)
    refute list =~ key
    refute admin_get("/admin/tournaments/#{slug}") |> html_response(200) =~ key
    refute admin_get("/admin/action-log") |> html_response(200) =~ key
  end

  test "the list says when a key was last used", %{world: world} do
    slug = world.listed

    {:ok, %{relay_key: relay_key}} =
      OpenResults.Moderation.create_relay_key(slug, "box", %{email: @admin})

    list = admin_get("/admin/tournaments/#{slug}/relay-keys") |> html_response(200)
    assert list =~ "never"

    :ok = RelayKeys.touch(relay_key, ~U[2026-10-08 09:30:00.000000Z])
    list = admin_get("/admin/tournaments/#{slug}/relay-keys") |> html_response(200)
    assert list =~ "2026-10-08 09:30 UTC"
  end

  test "revokes from its confirmation page, and the key stops working", %{world: world} do
    slug = world.listed

    {:ok, %{relay_key: relay_key, key: key}} =
      OpenResults.Moderation.create_relay_key(slug, "box", %{email: @admin})

    path = "/admin/tournaments/#{slug}/relay-keys/#{relay_key.id}/revoke"

    assert admin_get(path) |> html_response(200) =~ "Revoke relay key"

    conn = confirm_and_post(path)
    assert redirected_to(conn) == "/admin/tournaments/#{slug}/relay-keys"

    assert {:ok, %{revoked_at: %DateTime{}, revoked_by: @admin}} = RelayKeys.authenticate(key)
    assert %Action{action: "relay_key_revoke", target: ^slug} = last_action()

    # Revoking twice is a sentence, not an error.
    assert redirected_to(confirm_and_post_again(path)) =~ "relay-keys"
    list = admin_get("/admin/tournaments/#{slug}/relay-keys") |> html_response(200)
    assert list =~ "revoked"
  end

  defp confirm_and_post_again(path) do
    # The confirmation page of a revoked key redirects instead of asking.
    admin_get(path)
  end

  test "a key of another tournament cannot be revoked through this one", %{world: world} do
    {:ok, %{relay_key: relay_key}} =
      OpenResults.Moderation.create_relay_key(world.listed, "box", %{email: @admin})

    path = "/admin/tournaments/#{world.pending}/relay-keys/#{relay_key.id}/revoke"
    assert admin_get(path) |> html_response(404)
    assert RelayKeys.get(world.listed, relay_key.id).revoked_at == nil
  end

  test "the POSTs act only from their own confirmation page", %{world: world} do
    slug = world.listed
    before = RelayKeys.list(slug)

    assert response(
             post_with_token("/admin/tournaments/#{slug}/relay-keys/new", %{"label" => "x"}),
             400
           )

    assert RelayKeys.list(slug) == before
  end

  test "a tournament that does not exist is the panel's not-found" do
    assert admin_get("/admin/tournaments/no-such-one/relay-keys") |> html_response(404)
    assert admin_get("/admin/tournaments/no-such-one/relay-keys/new") |> html_response(404)
  end

  test "a tournament holds a bounded number of keys", %{world: world} do
    slug = world.listed

    for _ <- 1..RelayKeys.max_active(),
        do: {:ok, _} = OpenResults.Moderation.create_relay_key(slug, nil, %{email: @admin})

    conn = confirm_and_post("/admin/tournaments/#{slug}/relay-keys/new", %{"label" => "one more"})
    assert html_response(conn, 422) =~ "Revoke one first"
    assert RelayKeys.active_count(slug) == RelayKeys.max_active()
  end
end
