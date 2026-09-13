defmodule OpenResults.BackupTest do
  @moduledoc """
  Backups of the published record.

  Nothing in this database is reproducible - the snapshots ARE the record,
  `/history?at=` answers a question that cannot be recomputed, the queue holds
  entries nobody has reviewed, and the keys decide who may withdraw a
  tournament. So the test that matters is that all of it comes back.

  Sources are built by hand rather than through the sandbox, for the same
  reason as the arbiter app's: a backup copies the database FILE, and the
  sandbox keeps a test's rows in a transaction no other connection can see.
  """
  use OpenResults.DataCase, async: false

  alias OpenResults.Backup

  setup do
    dir = Path.join(System.tmp_dir!(), "orbak-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm(live_database() <> ".restored")
    end)

    Application.delete_env(:openresults, :backup_passphrase)
    on_exit(fn -> Application.delete_env(:openresults, :backup_passphrase) end)

    {:ok, dir: dir}
  end

  defp live_database, do: Application.get_env(:openresults, OpenResults.Repo)[:database]

  defp source(dir, sql \\ []) do
    path = Path.join(dir, "source-#{System.unique_integer([:positive])}.db")

    {:ok, conn} = Exqlite.Sqlite3.open(live_database())
    :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{path}'")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, conn} = Exqlite.Sqlite3.open(path)

    for table <- ~w(snapshots registrations tournament_keys) do
      :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM #{table}")
    end

    Enum.each(sql, &(:ok = Exqlite.Sqlite3.execute(conn, &1)))
    :ok = Exqlite.Sqlite3.close(conn)

    path
  end

  defp with_snapshot(dir) do
    source(dir, [
      """
      INSERT INTO snapshots (tournament_slug, version, source_app, source_version,
                             published_at, received_at, payload)
      VALUES ('gent-open', 1, 'openpairings', '0.17.1',
              '2026-08-29T09:00:00Z', '2026-08-29T09:00:01Z',
              '{"tournament":{"slug":"gent-open","name":"Gent Open"}}')
      """,
      """
      INSERT INTO tournament_keys (tournament_slug, key_hash, claimed_at)
      VALUES ('gent-open', 'a-hash-that-must-survive', '2026-08-29 09:00:00.000000')
      """
    ])
  end

  describe "creating and restoring" do
    test "the snapshots and the keys both come back", %{dir: dir} do
      src = with_snapshot(dir)

      {:ok, path} = Backup.create(dir: dir, source: src)
      assert {:ok, info} = Backup.verify(path)
      assert info.snapshots == 1

      {:ok, restored} = Backup.restore(path)

      {:ok, conn} = Exqlite.Sqlite3.open(restored)
      {:ok, s1} = Exqlite.Sqlite3.prepare(conn, "SELECT tournament_slug, payload FROM snapshots")
      {:ok, [[slug, payload]]} = Exqlite.Sqlite3.fetch_all(conn, s1)
      {:ok, s2} = Exqlite.Sqlite3.prepare(conn, "SELECT key_hash FROM tournament_keys")
      {:ok, [[hash]]} = Exqlite.Sqlite3.fetch_all(conn, s2)
      # Released before the close, or the `.restored` file stays open until the
      # statements are collected and survives on_exit's delete on Windows.
      :ok = Exqlite.Sqlite3.release(conn, s1)
      :ok = Exqlite.Sqlite3.release(conn, s2)
      :ok = Exqlite.Sqlite3.close(conn)

      assert slug == "gent-open"
      assert payload =~ "Gent Open"

      # The key is what decides who may withdraw a published tournament, and
      # it exists nowhere else.
      assert hash == "a-hash-that-must-survive"
    end

    test "nothing is emptied on the way out", %{dir: dir} do
      # The arbiter app strips its rating lists because a sync rebuilds them.
      # There is no equivalent here, and a backup that quietly dropped a table
      # would be losing the only copy.
      src = with_snapshot(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)
      {:ok, info} = Backup.verify(path)

      for table <- ~w(snapshots registrations tournament_keys schema_migrations) do
        assert table in info.tables
      end
    end

    test "recovers beside the live database, never over it", %{dir: dir} do
      src = with_snapshot(dir)
      before = File.stat!(live_database()).size

      {:ok, path} = Backup.create(dir: dir, source: src)
      {:ok, restored} = Backup.restore(path)

      assert String.ends_with?(restored, ".restored")
      assert File.stat!(live_database()).size == before
    end
  end

  describe "refusing the wrong file" do
    test "an OpenPairings backup is not an OpenResults one", %{dir: dir} do
      # The two formats are identical in shape on purpose, so the magic is the
      # only thing standing between a tired operator at midnight and a
      # database that opens perfectly and is entirely wrong.
      wrong = Path.join(dir, "openpairings-2026-08-29T00-00-00Z.orbak")
      File.write!(wrong, "OPBAK1
{\"app\":\"openpairings\"}
body")

      assert {:error, message} = Backup.verify(wrong)
      assert message =~ "not an OpenResults backup"
    end

    test "and neither is a text file", %{dir: dir} do
      junk = Path.join(dir, "notes.orbak")
      File.write!(junk, "dear diary")

      assert {:error, _} = Backup.verify(junk)
    end
  end

  describe "encryption" do
    setup do
      Application.put_env(:openresults, :backup_passphrase, "a long and unguessable one")
      :ok
    end

    test "round-trips, and the plaintext is not on disk", %{dir: dir} do
      src = with_snapshot(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)

      assert [%{encrypted: true}] = Backup.list(dir: dir)

      # The queue carries the email addresses people gave the entry form.
      refute File.read!(path) =~ "Gent Open"
      assert {:ok, %{snapshots: 1}} = Backup.verify(path)
    end

    test "a wrong passphrase is refused rather than partly applied", %{dir: dir} do
      src = with_snapshot(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)

      Application.put_env(:openresults, :backup_passphrase, "not that one")

      assert {:error, message} = Backup.verify(path)
      assert message =~ "assphrase"
    end
  end

  describe "retention" do
    # Days since 2026-09-13 (restore drill, finding 12): it was a count of
    # files, every boot spent one, and "30" was a month only on a box nobody
    # restarted.
    test "keeps what is younger than the window and removes what is older", %{dir: dir} do
      src = source(dir)

      for day <- 1..4 do
        stamp = DateTime.new!(Date.new!(2026, 8, day), ~T[12:00:00])
        {:ok, _} = Backup.create(dir: dir, source: src, stamp: stamp)
      end

      # Two more on the 4th - deploys - count once each, not against a number.
      for hour <- [13, 14] do
        stamp = DateTime.new!(~D[2026-08-04], Time.new!(hour, 0, 0))
        {:ok, _} = Backup.create(dir: dir, source: src, stamp: stamp)
      end

      # Two days, seen from the 4th at 18:00: the 3rd at noon is 30 hours old
      # and stays; the 2nd at noon, 54 hours, goes.
      assert Backup.prune(dir: dir, days: 2, now: ~U[2026-08-04 18:00:00Z]) == 2

      assert Backup.list(dir: dir) |> Enum.map(&{&1.created_at.day, &1.created_at.hour}) ==
               [{4, 14}, {4, 13}, {4, 12}, {3, 12}]
    end

    test "the newest is kept however old", %{dir: dir} do
      src = source(dir)
      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2020-01-01 00:00:00Z])
      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2020-01-02 00:00:00Z])

      assert Backup.prune(dir: dir, days: 30, now: ~U[2026-09-13 00:00:00Z]) == 1
      assert [%{created_at: ~U[2020-01-02 00:00:00Z]}] = Backup.list(dir: dir)
    end

    test "BACKUP_RETENTION that is not a whole number of days, at least one, stops the boot" do
      runtime = Path.expand("../../config/runtime.exs", __DIR__)
      previous = System.get_env("BACKUP_RETENTION")

      read = fn value ->
        System.put_env("BACKUP_RETENTION", value)
        Config.Reader.read!(runtime, env: :test)
      end

      try do
        assert read.("14")[:openresults][:backup_retention] == 14

        # Not "": on Windows setting a variable to nothing deletes it.
        for bad <- ["0", "-1", "30d", "1.5"] do
          assert_raise RuntimeError, ~r/BACKUP_RETENTION is a number of days/, fn ->
            read.(bad)
          end
        end
      after
        if previous,
          do: System.put_env("BACKUP_RETENTION", previous),
          else: System.delete_env("BACKUP_RETENTION")
      end
    end
  end

  describe "the scheduler's first run" do
    @interval :timer.hours(24)

    test "is a few minutes after boot when there is no backup, or the newest is a day old" do
      assert Backup.Scheduler.first_delay(nil, @interval) == :timer.minutes(5)
      assert Backup.Scheduler.first_delay(:timer.hours(25), @interval) == :timer.minutes(5)
    end

    test "waits for the newest to come due, so a restart does not spend a backup" do
      assert Backup.Scheduler.first_delay(:timer.hours(2), @interval) == :timer.hours(22)
      assert Backup.Scheduler.first_delay(0, @interval) == @interval

      assert Backup.Scheduler.first_delay(@interval - :timer.minutes(1), @interval) ==
               :timer.minutes(5)
    end

    test "reads the newest backup's age from its header, never below zero", %{dir: dir} do
      src = source(dir)
      assert Backup.newest_age_ms(dir: dir) == nil

      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2026-09-13 10:00:00Z])

      assert Backup.newest_age_ms(dir: dir, now: ~U[2026-09-13 12:00:00Z]) == :timer.hours(2)
      assert Backup.newest_age_ms(dir: dir, now: ~U[2026-09-13 09:00:00Z]) == 0
    end
  end
end
