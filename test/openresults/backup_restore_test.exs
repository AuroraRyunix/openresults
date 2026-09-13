defmodule OpenResults.BackupRestoreTest do
  @moduledoc """
  The restore drill of 2026-09-13 (`docs/restore-drill-2026-09-13.md`), kept.

  `OpenResults.BackupTest` proves a file is written and that the snapshots and
  keys are inside it. This proves the half that justifies having backups at
  all: that what `restore/1` hands back is a database this app runs on - every
  migration recorded, every table and row of today's schema present, the
  contexts reading it - and that `verify/1` refuses the files the drill showed
  it used to accept, without leaving anything behind.

  Sources are built by hand for the reason the other file gives: a backup
  copies the database FILE, and the sandbox keeps a test's rows where no other
  connection can see them.
  """
  use OpenResults.DataCase, async: false

  alias OpenResults.Backup

  @tables ~w(snapshots registrations tournament_keys installations tournaments reports
             address_blocks settings moderation_actions)

  setup do
    dir = Path.join(System.tmp_dir!(), "orbak-drill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)

      for suffix <- ["", "-wal", "-shm"],
          do: File.rm(live_database() <> ".restored" <> suffix)
    end)

    Application.delete_env(:openresults, :backup_passphrase)
    on_exit(fn -> Application.delete_env(:openresults, :backup_passphrase) end)

    {:ok, dir: dir}
  end

  defp live_database, do: Application.get_env(:openresults, OpenResults.Repo)[:database]

  # Today's schema, every table emptied, then one or more rows in EVERY table -
  # the public-publishing ones included, which arrived after the backup code was
  # written and are exactly what a quiet omission would lose.
  defp full_source(dir) do
    path = Path.join(dir, "source-#{System.unique_integer([:positive])}.db")

    {:ok, conn} = Exqlite.Sqlite3.open(live_database())
    :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{path}'")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, conn} = Exqlite.Sqlite3.open(path)

    for table <- @tables, do: :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM #{table}")

    stamp = "2026-09-13T00:00:00.000000Z"

    for sql <- [
          """
          INSERT INTO snapshots (tournament_slug, version, source_app, source_version, published_at, received_at, payload)
          VALUES ('drill-open', 1, 'openpairings', '0.60.0', '2026-09-13T00:00:00Z', '#{stamp}',
                  '{"tournament":{"slug":"drill-open","name":"Drill Open"}}')
          """,
          """
          INSERT INTO registrations (tournament_slug, version, received_at, payload)
          VALUES ('drill-open', 1, '#{stamp}', '{"name":"Entrant, Anna","email":"anna@example.org"}')
          """,
          "INSERT INTO tournament_keys (tournament_slug, key_hash, claimed_at) VALUES ('drill-open', 'key-hash', '#{stamp}')",
          """
          INSERT INTO installations (id, key_hash, client, client_version, status, created_from, last_seen_at, last_seen_from, inserted_at, updated_at)
          VALUES ('in_drillrevkd', '#{OpenResults.Installations.hash("orik_drill")}', 'OpenPairings', '0.60.0', 'revoked',
                  '198.51.100.10', '#{stamp}', '198.51.100.10', '#{stamp}', '#{stamp}')
          """,
          """
          INSERT INTO tournaments (slug, status, installation_id, minted_at, inserted_at, updated_at)
          VALUES ('drill-open', 'hidden', 'in_drillrevkd', '#{stamp}', '#{stamp}', '#{stamp}')
          """,
          """
          INSERT INTO reports (tournament_slug, reason, details, contact_email, client_address, status, inserted_at, updated_at)
          VALUES ('drill-open', 'personal_data', 'please remove', 'reporter@example.org', '192.0.2.50', 'open', '#{stamp}', '#{stamp}')
          """,
          """
          INSERT INTO address_blocks (cidr, reason, expires_at, created_by, inserted_at, updated_at)
          VALUES ('203.0.113.0/24', 'drill', '2026-10-01T00:00:00.000000Z', 'ops@example.org', '#{stamp}', '#{stamp}')
          """,
          """
          INSERT INTO settings (key, value, updated_by, inserted_at, updated_at)
          VALUES ('registration_open', 1, 'ops@example.org', '#{stamp}', '#{stamp}')
          """,
          """
          INSERT INTO moderation_actions (actor, action, target_type, target, details, inserted_at)
          VALUES ('ops@example.org', 'revoke', 'installation', 'in_drillrevkd', '{}', '#{stamp}')
          """
        ] do
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    end

    :ok = Exqlite.Sqlite3.close(conn)
    path
  end

  defp query(path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, st} = Exqlite.Sqlite3.prepare(conn, sql)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, st)
    :ok = Exqlite.Sqlite3.release(conn, st)
    :ok = Exqlite.Sqlite3.close(conn)
    rows
  end

  defp counts(path),
    do: for(t <- @tables, into: %{}, do: {t, query(path, "SELECT COUNT(*) FROM #{t}")})

  defp migration_files do
    Application.app_dir(:openresults, "priv/repo/migrations")
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/\A\d+_\w+\.exs\z/, &1))
  end

  describe "a restored database is one this app runs on" do
    test "every migration recorded, every table and row back, and the contexts read it", %{
      dir: dir
    } do
      src = full_source(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)
      {:ok, restored} = Backup.restore(path)

      # Row for row, table for table - including the public-publishing tables.
      assert counts(restored) == counts(src)
      assert Enum.all?(counts(src), fn {_table, [[n]]} -> n > 0 end)

      # Boot the app's own Repo on the restored file, outside the sandbox, and
      # ask the questions the app asks at boot and on its first requests.
      repo =
        start_supervised!(%{
          id: :restored_repo,
          start:
            {OpenResults.Repo, :start_link,
             [[name: nil, database: restored, pool: DBConnection.ConnectionPool, pool_size: 1]]}
        })

      previous = OpenResults.Repo.put_dynamic_repo(repo)

      try do
        migrations = Ecto.Migrator.migrations(OpenResults.Repo)
        assert length(migrations) == length(migration_files())
        assert Enum.all?(migrations, fn {status, _version, _name} -> status == :up end)

        assert OpenResults.Settings.all().registration_open == true
        assert %{status: "revoked"} = OpenResults.Installations.get("in_drillrevkd")
        assert %{status: "hidden"} = OpenResults.Tournaments.get("drill-open")
        assert [%{tournament_slug: "drill-open"}] = OpenResults.Snapshots.history("drill-open")
        assert [%{action: "revoke"}] = OpenResults.Moderation.list_actions(%{})
      after
        OpenResults.Repo.put_dynamic_repo(previous)
      end
    end

    test "it comes back in WAL mode with no sidecar files, so the first boot does not race its pool into it",
         %{dir: dir} do
      src = full_source(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)
      {:ok, restored} = Backup.restore(path)

      # `VACUUM INTO` writes a rollback-journal database. Handed over like that,
      # every pooled connection of the next boot tried to switch it to WAL at
      # once and the losers logged "database is locked" - on the first boot
      # after a restore, which is the worst moment to print an error.
      assert [["wal"]] = query(restored, "PRAGMA journal_mode")

      # And nothing beside it: moving the file must move the whole database.
      refute File.exists?(restored <> "-wal")
      refute File.exists?(restored <> "-shm")
    end
  end

  describe "verify/1 refuses what the drill showed it accepting" do
    test "a correct envelope around a database that fails its integrity check", %{dir: dir} do
      src = full_source(dir)
      {:ok, good} = Backup.create(dir: dir, source: src)
      bad = damage_one_table(good, "tournament_keys", dir)

      # The schema is intact and `snapshots` counts - the checks verify/1 used
      # to stop at - so only reading every page finds it.
      assert {:error, message} = Backup.verify(bad)
      assert message =~ "integrity"

      File.rm(live_database() <> ".restored")
      assert {:error, _} = Backup.restore(bad)
      refute File.exists?(live_database() <> ".restored")
    end

    for {label, iterations} <- [{"far too low", 1}, {"absurdly high", 5_000_000_000}] do
      test "an encrypted backup whose header asks for #{label} PBKDF2 iterations", %{dir: dir} do
        Application.put_env(:openresults, :backup_passphrase, "drill passphrase")
        {:ok, path} = Backup.create(dir: dir, source: full_source(dir))

        rewrite_iterations(path, unquote(iterations))

        # Read before the tag can be checked, so the count is the file's word
        # against ours. Low weakens the KDF; high wedges the command with no
        # cancel - 20 million took 7.6 s in the drill, 5 billion is hours.
        assert {:error, message} = Backup.verify(path)
        assert message =~ "PBKDF2 iterations"
      end
    end

    test "and still honours the count it writes", %{dir: dir} do
      Application.put_env(:openresults, :backup_passphrase, "drill passphrase")
      {:ok, path} = Backup.create(dir: dir, source: full_source(dir))

      [_magic, header, _payload] = String.split(File.read!(path), "\n", parts: 3)
      rewrite_iterations(path, Jason.decode!(header)["crypto"]["iterations"])

      assert {:ok, %{snapshots: 1}} = Backup.verify(path)
    end

    test "leaves no staging copy behind, accepted or refused", %{dir: dir} do
      # The staging copy is the whole database, decrypted. On Windows it used
      # to stay in the temp directory after EVERY verify - the connection was
      # closed with its statements still open, so SQLite kept the file - and
      # after every refusal on any system, because a refusal never closed it.
      private = Path.join(dir, "tmp")
      File.mkdir_p!(private)
      previous = System.get_env("TMPDIR")
      System.put_env("TMPDIR", private)

      try do
        {:ok, good} = Backup.create(dir: dir, source: full_source(dir))
        assert {:ok, _} = Backup.verify(good)
        assert {:error, _} = Backup.verify(damage_one_table(good, "tournament_keys", dir))
        assert {:error, _} = Backup.verify(not_a_database(good, dir))

        assert File.ls!(private) == []
      after
        if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
      end
    end
  end

  describe "retention" do
    for keep <- [0, -1, -3] do
      test "a count of #{keep} still never removes the newest", %{dir: dir} do
        src = full_source(dir)

        for day <- 1..4 do
          {:ok, _} =
            Backup.create(
              dir: dir,
              source: src,
              stamp: DateTime.new!(Date.new!(2026, 9, day), ~T[02:00:00])
            )
        end

        # `Enum.drop(list, 0)` deleted every backup, the one just written
        # included, and a negative count dropped from the other end - keeping
        # the OLDEST and deleting the newest.
        Backup.prune(dir: dir, keep: unquote(keep))

        assert [%{created_at: newest}] = Backup.list(dir: dir)
        assert newest.day == 4
      end
    end
  end

  describe "mix openresults.backup" do
    test "takes a name exactly as --list prints it", %{dir: dir} do
      {:ok, path} = Backup.create(dir: dir, source: full_source(dir))
      previous = Application.get_env(:openresults, :backup_dir)
      Application.put_env(:openresults, :backup_dir, dir)

      try do
        # The drill typed the listed name and got "no such file".
        assert Mix.Tasks.Openresults.Backup.resolve(Path.basename(path)) == path
        # A real path is taken as given; an unknown bare name is left alone
        # for File.read to refuse in its own words.
        assert Mix.Tasks.Openresults.Backup.resolve(path) == path
        assert Mix.Tasks.Openresults.Backup.resolve("nope.orbak") == "nope.orbak"
      after
        if previous,
          do: Application.put_env(:openresults, :backup_dir, previous),
          else: Application.delete_env(:openresults, :backup_dir)
      end
    end

    test "prints a swap that moves the WAL with the database and migrates before starting" do
      text =
        Mix.Tasks.Openresults.Backup.swap_instructions(
          "/var/lib/openresults/openresults.db.restored",
          "/var/lib/openresults/openresults.db",
          "/apps/web/openresults"
        )

      # Moving the .db alone left its -wal beside the restored file, and SQLite
      # served the old database through it. Every sidecar goes with the file.
      assert text =~ "for f in openresults.db openresults.db-wal openresults.db-shm"
      assert text =~ "openresults.db.before-restore-$stamp"
      assert text =~ "mv openresults.db.restored openresults.db"
      assert text =~ "mix ecto.migrate"

      # Migrate comes after the swap and before the start.
      [before_start, _] = String.split(text, "systemctl start openresults", parts: 2)
      assert before_start =~ "mix ecto.migrate"
      assert before_start =~ "mv openresults.db.restored openresults.db"
    end
  end

  # The root page of `table` with every cell pointer aimed at the page header:
  # the page still parses, the table still exists, every row read from it is
  # garbage. Wrapped back into a perfectly valid envelope.
  defp damage_one_table(backup_path, table, dir) do
    [magic, header, payload] = String.split(File.read!(backup_path), "\n", parts: 3)
    plain = :zlib.gunzip(payload)
    work = Path.join(dir, "damage-#{System.unique_integer([:positive])}.db")
    File.write!(work, plain)
    [[root]] = query(work, "SELECT rootpage FROM sqlite_master WHERE name = '#{table}'")
    [[page_size]] = query(work, "PRAGMA page_size")
    File.rm!(work)

    offset = (root - 1) * page_size
    <<before::binary-size(^offset), page::binary-size(^page_size), rest::binary>> = plain
    <<kind, _::binary-size(2), cells::16, _::binary>> = page
    pointers_at = if kind in [0x0D, 0x0A], do: 8, else: 12

    scrambled =
      for i <- 0..(cells - 1), reduce: page do
        acc ->
          at = pointers_at + 2 * i
          <<head::binary-size(^at), _::16, tail::binary>> = acc
          head <> <<13::16>> <> tail
      end

    damaged = Path.join(dir, "damaged-#{table}.orbak")

    File.write!(
      damaged,
      magic <> "\n" <> header <> "\n" <> :zlib.gzip(before <> scrambled <> rest)
    )

    damaged
  end

  defp not_a_database(backup_path, dir) do
    [magic, header, _payload] = String.split(File.read!(backup_path), "\n", parts: 3)
    path = Path.join(dir, "not-a-database.orbak")

    File.write!(
      path,
      magic <> "\n" <> header <> "\n" <> :zlib.gzip(:crypto.strong_rand_bytes(8192))
    )

    path
  end

  defp rewrite_iterations(path, iterations) do
    [magic, header, payload] = String.split(File.read!(path), "\n", parts: 3)

    header =
      header
      |> Jason.decode!()
      |> put_in(["crypto", "iterations"], iterations)
      |> Jason.encode!()

    File.write!(path, magic <> "\n" <> header <> "\n" <> payload)
  end
end
