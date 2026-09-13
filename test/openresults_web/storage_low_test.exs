defmodule OpenResultsWeb.StorageLowTest do
  @moduledoc """
  The free-disk floor over HTTP - `docs/public-publishing.md`, "Storage
  bounds": installation keys get 503 `storage_low` on mint and publish, and
  nothing else changes.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.DiskSpaceHelpers
  import OpenResults.PublicPublishingFixtures
  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  setup do
    RateLimit.reset()
    {installation, key} = installation!()
    slug = mint!(installation)
    tkey = random_key()
    slug |> payload() |> publish(key, tkey) |> json_response(200)
    {:ok, installation: installation, key: key, slug: slug, tkey: tkey}
  end

  test "below the floor: mint and publish are storage_low with Retry-After; nothing is stored",
       %{key: key, slug: slug, tkey: tkey} do
    disk_reads(free(3))
    republished = slug |> payload() |> SnapshotPayloads.republished()

    for conn <- [publish(republished, key, tkey), mint(key)] do
      assert %{"error" => "storage_low", "retry_after" => 300, "detail" => detail} =
               json_response(conn, 503)

      assert is_binary(detail)
      assert get_resp_header(conn, "retry-after") == ["300"]
    end

    assert [_only_the_first] = Snapshots.history(slug)
  end

  test "below the floor: history, registrations and delete still work", %{
    key: key,
    slug: slug,
    tkey: tkey
  } do
    disk_reads(free(3))

    assert json_response(history(slug, key), 200)
    assert json_response(registrations(slug, key, tkey), 200)
    assert %{"status" => "deleted"} = json_response(takedown(slug, key, tkey), 200)
  end

  test "below the floor: the operator token publishes as before" do
    disk_reads(free(3))
    assert json_response(unique_slug() |> payload() |> publish(operator_token()), 200)
  end

  test "an unknown measurement allows publishing", %{key: key, slug: slug, tkey: tkey} do
    disk_reads({:error, "no df on this system"})
    republished = slug |> payload() |> SnapshotPayloads.republished()

    assert json_response(publish(republished, key, tkey), 200)
    assert json_response(mint(key), 201)
  end

  test "the order: a pause is reported before storage, storage before size", %{
    key: key,
    slug: slug,
    tkey: tkey
  } do
    disk_reads(free(3))

    Application.put_env(:openresults, :installation_max_snapshot_bytes, 10)

    on_exit(fn ->
      Application.put_env(:openresults, :installation_max_snapshot_bytes, 3_145_728)
    end)

    republished = slug |> payload() |> SnapshotPayloads.republished()
    assert json_response(publish(republished, key, tkey), 503)["error"] == "storage_low"

    {:ok, _} = Moderation.put_setting(:public_publishing_paused, true, admin())
    assert json_response(publish(republished, key, tkey), 503)["error"] == "publishing_paused"
  end

  describe "the dashboard" do
    setup do
      reset_admin_access()
      configure_access()
      :ok
    end

    defp dashboard,
      do: admin_get("/admin") |> html_response(200) |> LazyHTML.from_document()

    defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

    test "warns while free space is below the floor, and shows the figures" do
      disk_reads(free(4))
      doc = dashboard()

      assert text(doc, "#storage-low") =~ "below the floor"
      assert text(doc, "#storage-low") =~ "storage_low"
      assert text(doc, "#storage-disk") =~ "4.0%"
      assert text(doc, "#storage-floor") =~ "10%"
      assert text(doc, "#storage-version-cap") =~ "20"
      assert text(doc, "#storage") =~ "Database file"
    end

    test "no warning above the floor, and an unmeasured disk says so without one" do
      disk_reads(free(50))
      refute dashboard() |> LazyHTML.query("#storage-low") |> Enum.any?()

      disk_reads({:error, "no df on this system"})
      doc = dashboard()
      refute doc |> LazyHTML.query("#storage-low") |> Enum.any?()
      assert text(doc, "#storage-disk") =~ "not measured"
      assert text(doc, "#storage-disk") =~ "no df on this system"
    end
  end
end
