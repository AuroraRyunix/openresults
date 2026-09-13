defmodule OpenResults.ModerationJournal do
  @moduledoc """
  A record of every moderation action that made the site safer, kept OUTSIDE
  the database, so that restoring a backup cannot undo it.

  ## Why

  The restore drill of 2026-09-13 restored a backup after the operator had
  kept working, and measured what came back (`docs/restore-drill-2026-09-13.md`,
  finding 2): a revoked installation's key minted a slug again, closed
  registration issued a key, a blocked range registered, a tournament deleted
  for personal data was back with its history, and a tournament its arbiter had
  withdrawn from OpenPairings was online again with its entry form open. The
  action log is restored to the same instant, so it could not say what to
  re-apply, and an owner's withdrawal was never in it at all.

  ## The file

  Beside the database, in the same directory, named after it:
  `/var/lib/openresults/openresults-moderation.jsonl`. Not inside the database,
  so a backup never contains it and a restore never touches it.
  `config :openresults, :moderation_journal` is a path to put it elsewhere, or
  `false` for none (the test environment).

  One JSON object per line, appended after the action committed:

      {"v":1,"at":"2026-09-13T10:02:11.123456Z","action":"hide","target":"gent-open"}
      {"v":1,"at":"...","action":"delete","target":"gent-open","by":"owner"}
      {"v":1,"at":"...","action":"revoke","target":"in_XWtJ...","hide_tournaments":true}
      {"v":1,"at":"...","action":"suspend","target":"in_XWtJ..."}
      {"v":1,"at":"...","action":"block_address","cidr":"192.0.2.0/24","expires_at":"..."}
      {"v":1,"at":"...","action":"put_setting","target":"registration_open","value":false}
      {"v":1,"at":"...","action":"put_setting","target":"public_publishing_paused","value":true}

  **Only the safer direction is journalled**: `delete` - the admin panel's,
  and an owner's or the operator's `DELETE /api/tournaments/:slug` (`by` says
  which) - `hide`, `revoke`, `suspend`, `block_address`, closing registration
  and pausing publishing. Approve, unhide, unsuspend, unblock, opening
  registration and unpausing are never written, so never replayed: after a
  restore they stay as the backup had them, and the operator redoes them
  deliberately. `at` is the action log row's own time where there is one.

  What a line holds: a slug, an installation id, a switch - and for a block,
  the address or range and its expiry, exactly what the action log already
  keeps for it. Not the block's reason, which is free text an operator typed;
  a replayed block says it was kept in force after a restore instead.

  ## Replay

  `replay/1` runs at every boot, after migrations, before the endpoint starts
  (`OpenResults.Application`). For every line it re-applies the action if -
  and only if - the database does not already know about it:

    * `delete`: if anything is still held for the slug that is OLDER than the
      line (a snapshot, a registration, the key claim, the tournament row),
      the database predates the delete, and the slug is purged again
      (`OpenResults.Takedown.purge/1`). A tournament published again under the
      slug after the delete is newer than the line, and stays.
    * `hide`, `suspend`, and the two switches: if the action log has any row
      about the same target at or after the line's time - the action itself,
      a later reversal, an earlier replay - the database already reflects it,
      and nothing happens. Otherwise the change is made if it is not already
      in force. A `hide` is also passed over when a later line deleted the
      slug.
    * `revoke`: revoked is final, so an installation that is not revoked is
      revoked (hiding its tournaments too if the original did).
    * `block_address`: as the others, keyed on the range; never re-created
      once its expiry has passed, and not twice.

  Every re-applied action writes one action log row with the actor
  `restore-replay` and the line's time in `journal_at`, which is also what
  makes the next boot see it as known. On a boot that followed no restore,
  every line is known and nothing happens.

  ## Trimming

  `trim/1` drops lines older than the oldest backup that could still be
  restored - the retention window plus a week's margin, or the oldest backup
  on disk less that margin if it is older (the newest backup is kept whatever
  its age). A restore cannot bring back anything older, so they can only ever
  be known. It runs after each boot's replay and after each scheduled backup.
  A backup copied off the box and kept longer than that is outside what this
  covers; the deployment guide says so.
  """

  import Ecto.Query

  alias OpenResults.AddressBlocks
  alias OpenResults.Backup
  alias OpenResults.Installations
  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.Registrations.Registration
  alias OpenResults.Repo
  alias OpenResults.Settings
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.Takedown
  alias OpenResults.TournamentKeys.TournamentKey
  alias OpenResults.Tournaments
  alias OpenResults.Tournaments.Tournament

  require Logger

  @actions ~w(delete hide revoke suspend block_address put_setting)
  @margin_days 7

  # The switch and the value that makes the site safer. The other direction is
  # never journalled - see the moduledoc.
  @safer_settings %{registration_open: false, public_publishing_paused: true}

  @doc "Where the journal is, or `nil` when it is switched off."
  @spec path() :: Path.t() | nil
  def path do
    case Application.get_env(:openresults, :moderation_journal) do
      false ->
        nil

      configured when is_binary(configured) and configured != "" ->
        configured

      _beside_the_database ->
        database = Application.get_env(:openresults, OpenResults.Repo)[:database]
        name = database |> Path.basename() |> Path.rootname()
        Path.join(Path.dirname(database), name <> "-moderation.jsonl")
    end
  end

  ## ---------- writing ----------

  @doc "A tournament deleted: `by` is `\"admin\"`, `\"owner\"` or `\"operator\"`."
  def record_delete(slug, by, %DateTime{} = at) when is_binary(slug),
    do: append(%{"action" => "delete", "target" => slug, "by" => by}, at)

  @doc "A tournament hidden."
  def record_hide(slug, %DateTime{} = at) when is_binary(slug),
    do: append(%{"action" => "hide", "target" => slug}, at)

  @doc "An installation revoked."
  def record_revoke(id, hide_tournaments, %DateTime{} = at) when is_binary(id),
    do:
      append(
        %{"action" => "revoke", "target" => id, "hide_tournaments" => hide_tournaments == true},
        at
      )

  @doc "An installation suspended."
  def record_suspend(id, %DateTime{} = at) when is_binary(id),
    do: append(%{"action" => "suspend", "target" => id}, at)

  @doc "An address or range blocked, until `expires_at`."
  def record_block(cidr, %DateTime{} = expires_at, %DateTime{} = at) when is_binary(cidr),
    do:
      append(
        %{
          "action" => "block_address",
          "cidr" => cidr,
          "expires_at" => DateTime.to_iso8601(expires_at)
        },
        at
      )

  @doc """
  A switch flipped. Written only for the safer value - registration closed,
  publishing paused; anything else is a no-op.
  """
  def record_setting(key, value, %DateTime{} = at) do
    case Map.fetch(@safer_settings, key) do
      {:ok, ^value} ->
        append(
          %{"action" => "put_setting", "target" => Atom.to_string(key), "value" => value},
          at
        )

      _other ->
        :ok
    end
  end

  # Never raises: the action has committed by the time this runs, and failing
  # the request now would only tell somebody it did not happen. A line that
  # could not be written is logged as an error - it is the one record that
  # would have kept the action in force after a restore.
  defp append(fields, at) do
    case path() do
      nil ->
        :ok

      file ->
        line =
          fields |> Map.merge(%{"v" => 1, "at" => DateTime.to_iso8601(at)}) |> Jason.encode!()

        case locked(fn -> write_line(file, line) end) do
          :ok ->
            :ok

          {:error, reason} = error ->
            Logger.error(
              "Could not write the moderation journal (#{file}): #{inspect(reason)}. " <>
                "#{fields["action"]} #{fields["target"] || fields["cidr"]} is in force, but a " <>
                "restore of an older backup would undo it."
            )

            error
        end
    end
  rescue
    error ->
      Logger.error("Could not write the moderation journal: #{Exception.message(error)}")
      {:error, error}
  end

  defp write_line(file, line) do
    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, device} <- :file.open(file, [:append, :raw, :binary]) do
      try do
        with :ok <- :file.write(device, line <> "\n"), do: :file.sync(device)
      after
        :file.close(device)
      end
    end
  end

  # Appends and the rewrite `trim/1` does are serialised, so a line appended
  # while the file is being rewritten cannot be lost with the old copy.
  defp locked(fun), do: :global.trans({{__MODULE__, :file}, self()}, fun)

  ## ---------- reading ----------

  @doc """
  Every well-formed line, oldest first, with `at` (and a block's `expires_at`)
  parsed. A line that does not parse - the torn last line of a write a crash
  interrupted - is skipped and logged, never fatal.
  """
  @spec entries(Path.t() | nil) :: [map()]
  def entries(nil), do: []

  def entries(file) do
    case File.read(file) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case parse(line) do
            {:ok, entry} ->
              [entry]

            :error ->
              Logger.warning("Skipped an unreadable line in the moderation journal #{file}")
              []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error("Could not read the moderation journal #{file}: #{inspect(reason)}")
        []
    end
  end

  defp parse(line) do
    with {:ok, %{"action" => action, "at" => at_text} = entry} when action in @actions <-
           Jason.decode(line),
         {:ok, at, _} <- DateTime.from_iso8601(at_text),
         {:ok, entry} <- well_formed(%{entry | "at" => at}) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp well_formed(%{"action" => "block_address", "cidr" => cidr, "expires_at" => text} = entry)
       when is_binary(cidr) and is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, expires_at, _} -> {:ok, %{entry | "expires_at" => expires_at}}
      _ -> :error
    end
  end

  defp well_formed(%{"action" => "put_setting", "target" => key, "value" => value} = entry)
       when is_boolean(value) do
    case Enum.find(Map.keys(@safer_settings), &(Atom.to_string(&1) == key)) do
      nil -> :error
      atom -> if(Map.fetch!(@safer_settings, atom) == value, do: {:ok, entry}, else: :error)
    end
  end

  defp well_formed(%{"action" => action, "target" => target} = entry)
       when action in ~w(delete hide revoke suspend) and is_binary(target),
       do: {:ok, entry}

  defp well_formed(_entry), do: :error

  ## ---------- replaying ----------

  @doc """
  Re-applies every journalled action a restored database does not know about,
  and returns how many it changed anything for. See the moduledoc.
  """
  @spec replay(keyword()) :: non_neg_integer()
  def replay(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    entries = opts |> Keyword.get_lazy(:path, &path/0) |> entries()

    entries
    |> Enum.with_index()
    |> Enum.count(fn {entry, index} ->
      later = Enum.drop(entries, index + 1)
      reapply(entry, later, now)
    end)
  end

  defp reapply(%{"action" => "delete", "target" => slug, "at" => at} = entry, _later, _now) do
    if older_data?(slug, at) do
      {:ok, counts} =
        Repo.transaction(fn ->
          counts = Takedown.purge(slug)
          replayed!("delete", "tournament", slug, entry, Map.put(counts, :by, entry["by"]))
          counts
        end)

      Tournaments.forget(slug)

      announce(
        entry,
        "#{counts.snapshots} snapshot(s) and #{counts.registrations} entries removed"
      )

      true
    else
      false
    end
  end

  defp reapply(%{"action" => "hide", "target" => slug, "at" => at} = entry, later, _now) do
    cond do
      deleted_later?(slug, later) ->
        false

      known?("tournament", slug, at) ->
        false

      true ->
        result =
          Repo.transaction(fn ->
            case Tournaments.transition(slug, ["pending", "listed"], "hidden") do
              {:ok, _tournament} -> replayed!("hide", "tournament", slug, entry, %{to: "hidden"})
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        Tournaments.forget(slug)
        applied?(result, entry)
    end
  end

  defp reapply(%{"action" => "revoke", "target" => id} = entry, _later, _now) do
    hide? = entry["hide_tournaments"] == true

    result =
      Repo.transaction(fn ->
        case Installations.transition(id, ["active", "suspended"], "revoked") do
          {:ok, _installation} ->
            hidden = if hide?, do: Tournaments.hide_all_for(id), else: []

            replayed!("revoke", "installation", id, entry, %{
              hide_tournaments: hide?,
              hidden: hidden
            })

            hidden

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    with {:ok, hidden} <- result, do: Enum.each(hidden, &Tournaments.forget/1)
    applied?(result, entry)
  end

  defp reapply(%{"action" => "suspend", "target" => id, "at" => at} = entry, _later, _now) do
    if known?("installation", id, at) do
      false
    else
      Repo.transaction(fn ->
        case Installations.transition(id, ["active"], "suspended") do
          {:ok, _installation} ->
            replayed!("suspend", "installation", id, entry, %{to: "suspended"})

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> applied?(entry)
    end
  end

  defp reapply(%{"action" => "block_address", "cidr" => cidr, "at" => at} = entry, _later, now) do
    expires_at = entry["expires_at"]

    cond do
      DateTime.compare(expires_at, now) != :gt -> false
      block_known?(cidr, at) -> false
      Enum.any?(AddressBlocks.list_active(now), &(&1.cidr == cidr)) -> false
      true -> reblock(cidr, expires_at, entry, now)
    end
  end

  defp reapply(
         %{"action" => "put_setting", "target" => key_text, "value" => value, "at" => at} = entry,
         _later,
         _now
       ) do
    key = Enum.find(Map.keys(@safer_settings), &(Atom.to_string(&1) == key_text))

    cond do
      known?("setting", key_text, at) ->
        false

      Settings.get(key) == value ->
        false

      true ->
        Repo.transaction(fn ->
          {:ok, _settings} = Settings.put(key, value, Moderation.restore_replay_actor())
          replayed!("put_setting", "setting", key_text, entry, %{value: value})
        end)
        |> applied?(entry)
    end
  end

  defp reblock(cidr, expires_at, entry, now) do
    Repo.transaction(fn ->
      reason = "kept in force after a restore (blocked #{DateTime.to_iso8601(entry["at"])})"

      case AddressBlocks.create(cidr, expires_at, reason, Moderation.restore_replay_actor(), now) do
        {:ok, block} ->
          replayed!("block_address", "address_block", Integer.to_string(block.id), entry, %{
            cidr: block.cidr,
            expires_at: DateTime.to_iso8601(block.expires_at)
          })

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> applied?(entry)
  end

  defp replayed!(action, target_type, target, entry, details) do
    Moderation.log_replay(
      action,
      target_type,
      target,
      Map.put(details, :journal_at, DateTime.to_iso8601(entry["at"]))
    )
  end

  defp applied?({:ok, _}, entry) do
    announce(entry, "applied again")
    true
  end

  defp applied?({:error, _reason}, _entry), do: false

  defp announce(entry, what) do
    Logger.warning(
      "Moderation journal: #{entry["action"]} #{entry["target"] || entry["cidr"]} of " <>
        "#{DateTime.to_iso8601(entry["at"])} was not in the database - #{what}."
    )
  end

  # Anything held for the slug that is older than the delete - the database
  # predates it.
  defp older_data?(slug, at) do
    Repo.exists?(from s in Snapshot, where: s.tournament_slug == ^slug and s.received_at < ^at) or
      Repo.exists?(
        from r in Registration, where: r.tournament_slug == ^slug and r.received_at < ^at
      ) or
      Repo.exists?(
        from k in TournamentKey, where: k.tournament_slug == ^slug and k.claimed_at < ^at
      ) or
      Repo.exists?(from t in Tournament, where: t.slug == ^slug and t.inserted_at < ^at)
  end

  defp known?(target_type, target, at) do
    Repo.exists?(
      from a in Action,
        where: a.target_type == ^target_type and a.target == ^target and a.inserted_at >= ^at
    )
  end

  # A block's action log rows are keyed by the block's id, which a re-created
  # block does not share, so they are matched on the range they name.
  defp block_known?(cidr, at) do
    Repo.exists?(
      from a in Action,
        where:
          a.target_type == "address_block" and a.action in ["block_address", "unblock"] and
            fragment("json_extract(?, '$.cidr')", a.details) == ^cidr and a.inserted_at >= ^at
    )
  end

  defp deleted_later?(slug, later),
    do: Enum.any?(later, &(&1["action"] == "delete" and &1["target"] == slug))

  ## ---------- trimming ----------

  @doc """
  Drops every line older than the oldest backup that could still be restored,
  and returns how many went. See the moduledoc.
  """
  @spec trim(keyword()) :: non_neg_integer()
  def trim(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case Keyword.get_lazy(opts, :path, &path/0) do
      nil ->
        0

      file ->
        cutoff = cutoff(now, Keyword.get_lazy(opts, :backups, &Backup.list/0))
        locked(fn -> rewrite(file, cutoff) end)
    end
  end

  @doc false
  def cutoff(now, backups) do
    margin = @margin_days * 86_400
    window = DateTime.add(now, -(Backup.retention() * 86_400 + margin), :second)

    case backups do
      [] ->
        window

      backups ->
        oldest = backups |> Enum.map(& &1.created_at) |> Enum.min(DateTime)
        Enum.min([window, DateTime.add(oldest, -margin, :second)], DateTime)
    end
  end

  defp rewrite(file, cutoff) do
    case File.read(file) do
      {:ok, contents} ->
        lines = String.split(contents, "\n", trim: true)

        kept =
          Enum.filter(lines, fn line ->
            case parse(line) do
              {:ok, %{"at" => at}} -> DateTime.compare(at, cutoff) != :lt
              :error -> false
            end
          end)

        gone = length(lines) - length(kept)
        tmp = file <> ".trimming"

        # Written beside it and renamed over it, so a crash mid-trim leaves the
        # old journal whole rather than half a new one. A failure is logged and
        # leaves the journal as it was: longer than it needs to be is harmless.
        with true <- gone > 0,
             :ok <- File.write(tmp, Enum.map(kept, &[&1, "\n"])),
             :ok <- File.rename(tmp, file) do
          gone
        else
          false ->
            0

          {:error, reason} ->
            File.rm(tmp)
            Logger.error("Could not trim the moderation journal #{file}: #{inspect(reason)}")
            0
        end

      {:error, _no_file} ->
        0
    end
  end

  ## ---------- at boot ----------

  @doc false
  # A supervision-tree entry that replays, trims and is gone: `start_link/1`
  # does the work and answers `:ignore`, so everything after it - the endpoint
  # above all - starts only once it has finished.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc false
  def start_link(_opts) do
    case replay() do
      0 -> :ok
      n -> Logger.warning("Moderation journal: re-applied #{n} action(s) a restore had undone.")
    end

    # A journal that could not be shortened is a slightly longer journal, not
    # a reason to keep the site down; the replay above is what may not fail.
    try do
      trim()
    rescue
      error -> Logger.error("Could not trim the moderation journal: #{Exception.message(error)}")
    end

    :ignore
  end
end
