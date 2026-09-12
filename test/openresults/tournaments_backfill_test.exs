defmodule OpenResults.TournamentsBackfillTest do
  @moduledoc """
  The migration that created `tournaments` backfilled every existing slug to
  `listed` with no owner. Its SQL, run against rows shaped like a production
  database from before the migration.
  """

  use OpenResults.DataCase, async: false

  alias OpenResults.Snapshots
  alias OpenResults.Tournaments
  alias OpenResults.Tournaments.Tournament

  @migration "priv/repo/migrations/20260912130100_create_tournaments.exs"

  defp migration do
    module = OpenResults.Repo.Migrations.CreateTournaments

    unless Code.ensure_loaded?(module), do: Code.require_file(@migration)

    module
  end

  test "every slug with snapshots gets one listed, ownerless row; nothing else is touched" do
    {:ok, _} =
      Snapshots.ingest(
        put_in(OpenResults.SnapshotPayloads.swiss(), ["tournament", "slug"], "legacy-a")
      )

    {:ok, _} =
      Snapshots.ingest(
        put_in(OpenResults.SnapshotPayloads.swiss(), ["tournament", "slug"], "legacy-b")
      )

    {:ok, _} =
      OpenResults.SnapshotPayloads.swiss()
      |> put_in(["tournament", "slug"], "legacy-b")
      |> OpenResults.SnapshotPayloads.republished()
      |> Snapshots.ingest()

    # Production-shaped: the rows exist, and the table the migration creates
    # does not have them yet.
    Repo.delete_all(Tournament)

    # A slug that already has a row keeps it.
    now = DateTime.utc_now()

    Repo.insert_all(Tournament, [
      %{slug: "legacy-a", status: "hidden", inserted_at: now, updated_at: now}
    ])

    # `apply/3`, because the migration is not part of the compiled app and
    # naming the call directly would warn at compile time.
    sql = apply(migration(), :backfill_sql, [~U[2026-09-12 13:01:00.123456Z]])
    Ecto.Adapters.SQL.query!(Repo, sql)

    assert [
             %Tournament{slug: "legacy-a", status: "hidden"},
             %Tournament{
               slug: "legacy-b",
               status: "listed",
               installation_id: nil,
               minted_at: nil,
               inserted_at: stamp
             }
           ] = Tournament |> order_by(:slug) |> Repo.all()

    assert stamp == ~U[2026-09-12 13:01:00.123456Z]

    Tournaments.forget("legacy-b")
    assert Tournaments.status("legacy-b") == :listed
  end
end
