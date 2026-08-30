defmodule OpenResults.BuildTest do
  @moduledoc """
  This app is the reason the identifier exists.

  On 2026-08-30 a deploy went out, the public player pages still looked old,
  and the version said `0.1.0` - which it had said for weeks. There was
  nothing on the screen to check. The cause was that the deploy script builds
  OpenPairings by default and needs `--openresults` to touch this app, so it
  had never been deployed at all.
  """
  # async: false - the tournament-page test writes a snapshot, and SQLite
  # holds one writer. Same reason the other write-touching files here are
  # serial.
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.Build

  test "the identifier carries more than the version" do
    refute Build.id() == Build.version()
    assert String.starts_with?(Build.id(), Build.version())
  end

  test "the ref is a short commit, or admits it does not know" do
    assert Build.ref() == "unknown" or Build.ref() =~ ~r/^[0-9a-f]{7,40}(-dirty)?$/
  end

  test "a test run is not a release build, and says so" do
    refute Build.release?()
    assert Build.long() =~ "not a release build"
  end

  test "it is in the footer of a page with no login" do
    # The whole point: answerable from outside, without an account.
    html = build_conn() |> get(~p"/") |> html_response(200)

    assert html =~ "build-id"
    assert html =~ Build.id()
  end

  test "and on a tournament page too, not just the front one" do
    swiss = OpenResults.SnapshotPayloads.swiss()
    {:ok, _} = OpenResults.Snapshots.ingest(swiss)
    slug = swiss["tournament"]["slug"]

    html = build_conn() |> get(~p"/t/#{slug}") |> html_response(200)

    assert html =~ Build.id()
  end
end
