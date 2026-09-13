defmodule OpenResults.Backup do
  @moduledoc """
  Backups of the published record.

  Smaller in every sense than the arbiter app's, and for one reason: **nothing
  here is reproducible.** That module empties the FIDE and KBSB rating lists on
  the way out because a sync rebuilds them. This database has no such tables.
  Every row in it - the snapshots, the registration queue, the tournament keys
  - exists only here, so all of it is copied.

  ## What is actually at risk

  The snapshots are a published record. An arbiter who loses their own machine
  can rebuild a tournament from what is here, and `/history?at=` answers "what
  did the standings say at 14:00" after a disputed result - a question that
  cannot be recomputed, only remembered. The registration queue holds entries
  nobody has reviewed yet, and the keys decide who may withdraw a tournament.

  ## Same file format, deliberately

  `ORBAK1` rather than `OPBAK1`, so a backup of one app cannot be restored into
  the other by a tired operator at midnight - the magic is checked before
  anything is unpacked. Everything else is the same shape, because two backup
  formats to remember is one too many.

  ## Restoring does not swap the live file

  A SQLite file cannot be replaced underneath an open connection pool without
  risking the thing being recovered. `restore/1` writes the recovered database
  beside the live one and returns the path. The swap is the operator's, and it
  is more than the three commands this once claimed - `docs/deployment.md`,
  "Restoring a backup", is the procedure, and the 2026-09-13 drill
  (`docs/restore-drill-2026-09-13.md`) is why each step is there:

    * the live database's `-wal` and `-shm` files move WITH it. SQLite pairs a
      database with whatever `-wal` sits beside it and has no way to tell that
      one belongs to a different file: the drill put a restored database next
      to the old one's WAL and read back a mixture of the two - the old action
      log, the backup's tournaments - with the integrity check saying "ok".
    * `mix ecto.migrate` runs before the start. `mix phx.server` does not
      migrate, and a backup older than the code boots, answers HTTP, and
      fails every page that touches a newer table.

  ## What verify/1 checks

  That the file is ours, that it decrypts and decompresses, that the tables no
  version of this app has run without are there, and that every page of the
  database reads back - `PRAGMA integrity_check`. The last one was missing
  until the drill: a backup of a database with one damaged table verified,
  restored, and failed its first query against that table.

  ## What a restore undoes

  Everything written after the backup, and on this server that includes
  moderation: a revoked installation key works again, a closed registration
  switch is open, an address block is gone, a hidden or deleted tournament is
  back - and so is a tournament its arbiter withdrew, whose key that arbiter's
  machine has already thrown away. The action log is restored to the same
  moment, so it cannot say what to re-apply. See the deployment guide.
  """

  @magic "ORBAK1"
  @cipher :aes_256_gcm
  @pbkdf2_iterations 210_000
  @key_bytes 32
  @salt_bytes 16
  @iv_bytes 12
  @stale_after_ms :timer.minutes(30)

  @doc "Writes a backup and returns its path."
  @spec create(keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def create(opts \\ []) do
    dir = Keyword.get(opts, :dir, directory())
    source = Keyword.get(opts, :source, database_path())
    stamp = Keyword.get_lazy(opts, :stamp, fn -> DateTime.utc_now() end)

    with :ok <- File.mkdir_p(dir) |> normalise("could not create #{dir}"),
         :ok <- sweep_staging(dir),
         {:ok, staged} <- vacuum_into(source, dir),
         {:ok, bytes} <- File.read(staged) |> normalise("could not read the staged copy") do
      File.rm(staged)
      write_envelope(dir, stamp, bytes)
    end
  end

  @doc "Every backup on disk, newest first."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    dir = Keyword.get(opts, :dir, directory())

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".orbak"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.map(&summarise/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

      {:error, _} ->
        []
    end
  end

  @doc """
  Deletes all but the newest `keep`, returning how many went.

  A count rather than an age: a server that was off for a fortnight should
  still have its last backups when it comes back.

  Never fewer than one, whatever it is given. `Enum.drop(list, 0)` is the
  whole list, so a count of 0 deleted every backup including the one the
  scheduler had just written, and a negative count drops from the other end -
  it kept the OLDEST and deleted the newest. Both were a `BACKUP_RETENTION`
  typo away.
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    keep = opts |> Keyword.get(:keep, retention()) |> at_least_one()

    list(opts)
    |> Enum.drop(keep)
    |> Enum.map(& &1.path)
    |> Enum.reduce(0, fn path, gone ->
      if File.rm(path) == :ok, do: gone + 1, else: gone
    end)
  end

  @doc """
  Unpacks `path` and checks it is a database this app could run on.

  The check runs on a staging copy in the temp directory, and that copy is the
  whole database - decrypted, for an encrypted backup - so it is deleted on
  every path out, refusals included. It used to survive both: a refusal never
  closed its connection, and on Windows even an accepted file stayed behind,
  because the connection was closed with statements still open and SQLite
  kept the file until they were collected.
  """
  @spec verify(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def verify(path) do
    with {:ok, bytes} <- unpack(path) do
      tmp = Path.join(System.tmp_dir!(), "orbak-verify-#{System.unique_integer([:positive])}.db")

      try do
        with :ok <- File.write(tmp, bytes) |> normalise("could not stage the file") do
          inspect_database(tmp)
        end
      after
        File.rm(tmp)
      end
    end
  end

  defp inspect_database(path) do
    with {:ok, conn} <- open(path) do
      try do
        with {:ok, tables} <- tables(conn),
             :ok <- require_tables(tables),
             :ok <- integrity(conn),
             {:ok, snapshots} <- scalar(conn, "SELECT COUNT(*) FROM snapshots") do
          {:ok, %{tables: tables, snapshots: snapshots}}
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  @doc """
  Recovers `path` beside the live database and returns where.

  The recovered file is switched to WAL before it is handed over, on one
  connection. `VACUUM INTO` writes a rollback-journal database, and the first
  boot on one had every pooled connection trying to make that switch at once:
  the losers logged "database is locked", on exactly the boot an operator is
  watching most closely.
  """
  @spec restore(Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def restore(path) do
    with {:ok, _info} <- verify(path),
         {:ok, bytes} <- unpack(path) do
      target = database_path() <> ".restored"

      # A `-wal` left beside an earlier `.restored` - somebody opened it to
      # look - would be replayed into the fresh copy the moment it is opened.
      Enum.each(["-wal", "-shm"], &File.rm(target <> &1))

      with :ok <- File.write(target, bytes) |> normalise("could not write #{target}"),
           :ok <- to_wal(target) do
        {:ok, target}
      end
    end
  end

  defp to_wal(path) do
    with {:ok, conn} <- open(path) do
      result = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
      Exqlite.Sqlite3.close(conn)

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, "could not switch #{path} to WAL: #{reason_text(reason)}"}
      end
    end
  end

  @doc "Where backups are kept."
  def directory do
    Application.get_env(:openresults, :backup_dir) ||
      Path.join(Path.dirname(database_path()), "backups")
  end

  @doc "How many are kept - never fewer than one, see `prune/1`."
  def retention do
    case Application.get_env(:openresults, :backup_retention, 30) do
      n when is_integer(n) -> at_least_one(n)
      _not_a_count -> 30
    end
  end

  defp at_least_one(n) when is_integer(n), do: max(n, 1)

  @doc "Whether backups are written encrypted."
  def encrypted?, do: not is_nil(passphrase())

  ## ---------- making one ----------

  defp vacuum_into(source, dir) do
    staged = Path.join(dir, "staging-#{System.unique_integer([:positive])}.db")

    # `VACUUM INTO` on its own connection: the documented way to copy a
    # database that is being written to, and it cannot run inside the
    # transaction a pooled connection may be in.
    with {:ok, conn} <- open(source) do
      result = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '" <> escape(staged) <> "'")
      Exqlite.Sqlite3.close(conn)

      case result do
        :ok ->
          {:ok, staged}

        {:error, reason} ->
          File.rm(staged)
          {:error, "could not copy the database: " <> to_string(reason)}
      end
    end
  end

  defp escape(path), do: String.replace(path, "'", "''")

  # A staging copy is a whole database, so one left behind per run would fill
  # the disk the backups exist to protect. Removing it immediately is attempted
  # and not relied on - a SQLite file can stay briefly locked after its handle
  # closes - and this sweep at the start of the next run is what guarantees
  # they cannot accumulate. Age-gated so a manual run during the scheduled one
  # does not have its copy pulled out from under it.
  defp sweep_staging(dir) do
    now = System.os_time(:millisecond)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, "staging-"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.each(fn path ->
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} when now - mtime * 1000 > @stale_after_ms -> File.rm(path)
            _ -> :ok
          end
        end)

        :ok

      {:error, _} ->
        :ok
    end
  end

  defp write_envelope(dir, stamp, bytes) do
    compressed = :zlib.gzip(bytes)
    {payload, crypto} = encrypt(compressed)

    header =
      Jason.encode!(%{
        "app" => "openresults",
        "version" => 1,
        "created_at" => stamp |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "compressed" => true,
        "encrypted" => crypto != nil,
        "plain_bytes" => byte_size(bytes),
        "crypto" => crypto
      })

    path = Path.join(dir, "openresults-#{file_stamp(stamp)}.orbak")

    case File.write(path, @magic <> "\n" <> header <> "\n" <> payload) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp encrypt(payload) do
    case passphrase() do
      nil ->
        {payload, nil}

      secret ->
        salt = :crypto.strong_rand_bytes(@salt_bytes)
        iv = :crypto.strong_rand_bytes(@iv_bytes)
        key = :crypto.pbkdf2_hmac(:sha256, secret, salt, @pbkdf2_iterations, @key_bytes)
        {ciphertext, tag} = :crypto.crypto_one_time_aead(@cipher, key, iv, payload, @magic, true)

        {ciphertext,
         %{
           "cipher" => "aes-256-gcm",
           "kdf" => "pbkdf2-sha256",
           "iterations" => @pbkdf2_iterations,
           "salt" => Base.encode64(salt),
           "iv" => Base.encode64(iv),
           "tag" => Base.encode64(tag)
         }}
    end
  end

  ## ---------- reading one ----------

  defp unpack(path) do
    with {:ok, raw} <- File.read(path) |> normalise("could not read #{path}"),
         {:ok, header, payload} <- split(raw),
         {:ok, compressed} <- decrypt(header, payload) do
      if header["compressed"] do
        try do
          {:ok, :zlib.gunzip(compressed)}
        rescue
          _ -> {:error, "the backup is corrupt - it did not decompress"}
        end
      else
        {:ok, compressed}
      end
    end
  end

  defp split(raw) do
    case String.split(raw, "\n", parts: 3) do
      [@magic, header, payload] ->
        case Jason.decode(header) do
          {:ok, decoded} -> {:ok, decoded, payload}
          {:error, _} -> {:error, "the backup's header is unreadable"}
        end

      _ ->
        # Catches an OpenPairings backup too, which is the point of a distinct
        # magic: the two are the same shape and restoring one into the other
        # would produce a database that opens and is entirely wrong.
        {:error, "that is not an OpenResults backup"}
    end
  end

  defp decrypt(%{"encrypted" => true, "crypto" => crypto}, payload) when is_map(crypto) do
    case passphrase() do
      nil ->
        {:error,
         "this backup is encrypted and no passphrase is configured - set " <>
           "OPENRESULTS_BACKUP_PASSPHRASE to the one it was written with"}

      secret ->
        with {:ok, iterations} <- checked_iterations(crypto["iterations"]) do
          salt = Base.decode64!(crypto["salt"])
          iv = Base.decode64!(crypto["iv"])
          tag = Base.decode64!(crypto["tag"])
          key = :crypto.pbkdf2_hmac(:sha256, secret, salt, iterations, @key_bytes)

          case :crypto.crypto_one_time_aead(@cipher, key, iv, payload, @magic, tag, false) do
            :error ->
              {:error, "wrong passphrase, or the backup has been altered since it was written"}

            plain ->
              {:ok, plain}
          end
        end
    end
  end

  defp decrypt(_header, payload), do: {:ok, payload}

  # The iteration count comes out of the file's own header, which is read
  # BEFORE the AEAD tag can be checked - it derives the key the tag is checked
  # with - so it is the file's word, not ours. Too low weakens a passphrase the
  # file was never written with; too high wedges `--verify`/`--restore` in a
  # PBKDF2 loop with no early exit and no cancel (20 million iterations took
  # 7.6 s in the 2026-09-13 drill; the header will happily say 5 billion).
  # OpenPairings bounded this after its 2026-09-01 sweep (L5) and this copy of
  # the format never learned it. The range is deliberately wide: it has to go
  # on accepting every count this app has written (@pbkdf2_iterations) and
  # leave room for that to rise.
  @min_pbkdf2_iterations 10_000
  @max_pbkdf2_iterations 2_000_000

  defp checked_iterations(nil), do: {:ok, @pbkdf2_iterations}

  defp checked_iterations(n)
       when is_integer(n) and n >= @min_pbkdf2_iterations and n <= @max_pbkdf2_iterations,
       do: {:ok, n}

  defp checked_iterations(n) do
    {:error,
     "this backup's header asks for #{inspect(n)} PBKDF2 iterations, which is outside " <>
       "the accepted range (#{@min_pbkdf2_iterations}-#{@max_pbkdf2_iterations}) - " <>
       "the file is corrupt or has been tampered with"}
  end

  defp summarise(path) do
    with {:ok, raw} <- File.read(path),
         [@magic, header, _] <- String.split(raw, "\n", parts: 3),
         {:ok, decoded} <- Jason.decode(header),
         {:ok, created_at, _} <- DateTime.from_iso8601(decoded["created_at"] || "") do
      %{
        path: path,
        size: byte_size(raw),
        created_at: created_at,
        encrypted: decoded["encrypted"] == true
      }
    else
      _ -> nil
    end
  end

  ## ---------- plumbing ----------

  defp open(path) do
    case Exqlite.Sqlite3.open(path) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "could not open the database: #{reason_text(reason)}"}
    end
  end

  # Every statement is released before its rows are returned. A connection
  # closed with a statement still prepared is not closed: SQLite defers it
  # until the statement is finalised, which here meant until the garbage
  # collector got round to it - and until then the file stayed open, so the
  # staging copy could not be deleted on Windows.
  defp rows(conn, sql) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, statement} ->
        try do
          Exqlite.Sqlite3.fetch_all(conn, statement)
        after
          Exqlite.Sqlite3.release(conn, statement)
        end

      {:error, _} = error ->
        error
    end
  end

  defp tables(conn) do
    case rows(conn, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [name] -> name end)}
      {:error, reason} -> {:error, "could not read the file's tables: #{reason_text(reason)}"}
    end
  end

  defp scalar(conn, sql) do
    case rows(conn, sql) do
      {:ok, [[value]]} -> {:ok, value}
      _ -> {:error, "the file opened but did not answer a simple query"}
    end
  end

  # Every page, not the handful the checks above touch: the drill's damaged
  # `tournament_keys` table passed them all. `integrity_check` is the thorough
  # form - it also cross-checks every index - and it only ever runs from the
  # command line, on a file that is about to become the live database.
  defp integrity(conn) do
    case rows(conn, "PRAGMA integrity_check") do
      {:ok, [["ok"]]} ->
        :ok

      {:ok, problems} ->
        first = problems |> List.flatten() |> Enum.take(3) |> Enum.join("; ")

        {:error,
         "the database inside fails its integrity check (#{first}) - restoring it would " <>
           "put a damaged database live; try an older backup"}

      {:error, reason} ->
        {:error,
         "the database inside could not be read through (#{reason_text(reason)}) - restoring " <>
           "it would put a damaged database live; try an older backup"}
    end
  end

  # SQLite's messages arrive as binaries that are not always printable - the
  # drill's damaged file produced `<<109, 97, 108, 102, ...>>` where
  # "malformed" was meant.
  defp reason_text(reason) when is_binary(reason) do
    text = String.replace(reason, <<0>>, "")
    if String.printable?(text), do: text, else: inspect(reason)
  end

  defp reason_text(reason), do: inspect(reason)

  # Not the full table list on purpose: a backup from a slightly older schema
  # should still restore, and demanding every table would refuse exactly the
  # backups somebody reaches for in an emergency.
  @required ~w(snapshots registrations schema_migrations)

  defp require_tables(tables) do
    case Enum.reject(@required, &(&1 in tables)) do
      [] ->
        :ok

      missing ->
        {:error, "that file is missing #{Enum.join(missing, ", ")} - it is not one of ours"}
    end
  end

  defp database_path do
    Application.get_env(:openresults, OpenResults.Repo)[:database] || "openresults.db"
  end

  defp passphrase do
    case Application.get_env(:openresults, :backup_passphrase) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  defp file_stamp(stamp) do
    stamp |> DateTime.truncate(:second) |> DateTime.to_iso8601() |> String.replace(":", "-")
  end

  defp normalise(:ok, _message), do: :ok
  defp normalise({:ok, value}, _message), do: {:ok, value}

  defp normalise({:error, reason}, message),
    do: {:error, "#{message}: #{:file.format_error(reason)}"}
end
