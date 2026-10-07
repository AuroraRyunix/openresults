defmodule OpenResultsWeb.AdminLiveDelayTest do
  @moduledoc """
  The broadcast delay as the panel sets it: shown on the tournament's page,
  changed the panel's usual way (a form, its confirmation marker, a CSRF
  token), logged, and refused with a sentence - never a 500 - when it is not
  a number of minutes.
  """

  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.LiveBoards
  alias OpenResults.Moderation.Action
  alias OpenResultsWeb.AdminWorld

  @admin "arbiter@example.org"

  setup do
    reset_admin_access()
    configure_access()
    {:ok, world: AdminWorld.build()}
  end

  test "the tournament's page says what the delay is and offers to change it", %{world: world} do
    page = world.listed |> then(&admin_get("/admin/tournaments/#{&1}")) |> html_response(200)

    assert page =~ ~s(id="tournament-live-delay")
    assert page =~ "none: spectators see the game as it is played"
    assert page =~ "/admin/tournaments/#{world.listed}/live-delay"

    {:ok, 20} = LiveBoards.put_delay(world.listed, 20, @admin)
    page = world.listed |> then(&admin_get("/admin/tournaments/#{&1}")) |> html_response(200)
    assert page =~ "20 minutes behind the game"
  end

  test "sets the delay from its confirmation page, and logs it", %{world: world} do
    path = "/admin/tournaments/#{world.listed}/live-delay"

    assert admin_get(path) |> html_response(200) =~ ~s(name="minutes")

    conn = confirm_and_post(path, %{"minutes" => "15"})
    assert redirected_to(conn) == "/admin/tournaments/#{world.listed}"
    assert LiveBoards.delay_minutes(world.listed) == 15

    assert %Action{actor: @admin, action: "live_delay", details: %{"from" => 0, "to" => 15}} =
             last_action()

    conn = confirm_and_post(path, %{"minutes" => "0"})
    assert redirected_to(conn) == "/admin/tournaments/#{world.listed}"
    assert LiveBoards.delay_minutes(world.listed) == 0
  end

  test "a number that is not minutes comes back to the form", %{world: world} do
    path = "/admin/tournaments/#{world.listed}/live-delay"

    for bad <- ["soon", "", "-5", "10.5", "99999", %{"x" => "1"}, ["5"]] do
      conn = confirm_and_post(path, %{"minutes" => bad})
      assert html_response(conn, 422) =~ "whole number of minutes"
    end

    assert LiveBoards.delay_minutes(world.listed) == 0
  end

  test "the POST acts only from its own confirmation page", %{world: world} do
    path = "/admin/tournaments/#{world.listed}/live-delay"
    conn = post_with_token(path, %{"minutes" => "5"})

    assert response(conn, 400)
    assert LiveBoards.delay_minutes(world.listed) == 0
  end

  test "a tournament that does not exist is the panel's not-found", %{world: _world} do
    assert admin_get("/admin/tournaments/no-such-one/live-delay") |> html_response(404)
  end
end
