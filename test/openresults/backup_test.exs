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
    test "keeps the newest and removes the rest", %{dir: dir} do
      src = source(dir)

      for day <- 1..4 do
        stamp = DateTime.new!(Date.new!(2026, 8, day), ~T[00:00:00])
        {:ok, _} = Backup.create(dir: dir, source: src, stamp: stamp)
      end

      assert Backup.prune(dir: dir, keep: 2) == 2
      assert [newest, _] = Backup.list(dir: dir)
      assert newest.created_at.day == 4
    end
  end
end
