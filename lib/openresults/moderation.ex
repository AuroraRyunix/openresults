defmodule OpenResults.Moderation do
  @moduledoc """
  Everything the admin panel does, and the log of it.

  The names and arities here are a contract: `docs/public-publishing.md`,
  "Moderation API". The panel is built against that section and only renders
  what these return, so a rename here is a broken panel.

  ## Actors

  `actor` is `%{email: String.t()}` - the address the panel's own
  authentication established. Anything else raises: a moderation action with
  nobody behind it is a bug in the caller, not an input to tolerate.

  ## The action log

  Every function that changes something writes one `OpenResults.Moderation.Action`
  in the same transaction as the change, so there is no change without its
  entry and no entry for a change that rolled back. Two entries are written
  from outside this module's functions, each with its own actor:

    * `break-glass` - `OpenResults.TournamentKeys`, when the operator token was
      presented where a tournament key belongs;
    * `retention` - `OpenResults.Retention`, the daily job.

  ## Return shapes

    * a changed tournament, installation, report or block comes back as
      `{:ok, struct}`;
    * a refusal is `{:error, atom}` - `:not_found`, `:invalid_status`,
      `:already_resolved`, `:installation_revoked`, `:unknown_setting` - or
      `{:error, %Ecto.Changeset{}}` where there is a form to redisplay
      (`block_address/4`);
    * `delete/2` returns `{:ok, counts}`, the same counts
      `DELETE /api/tournaments/:slug` answers with.

  Tournament listings carry three virtual fields filled from other tables:
  `name` (from the current snapshot, `nil` before the first publish),
  `last_published_at` and `open_reports`. Installation listings carry
  `tournament_count` (`pending` plus `listed`, the number the limit counts).
  """

  import Ecto.Query, warn: false

  require Logger

  alias OpenResults.AddressBlocks
  alias OpenResults.AddressBlocks.Block
  alias OpenResults.Installations
  alias OpenResults.Installations.Installation
  alias OpenResults.Moderation.Action
  alias OpenResults.QueryFilters
  alias OpenResults.Repo
  alias OpenResults.Reports
  alias OpenResults.Reports.Report
  alias OpenResults.Settings
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.Takedown
  alias OpenResults.Tournaments
  alias OpenResults.Tournaments.Tournament

  @type actor :: %{email: String.t()}

  @break_glass "break-glass"
  @retention "retention"

  # ---------------------------------------------------------------------------
  # Switches

  @doc "Both runtime switches."
  @spec settings() :: %{registration_open: boolean(), public_publishing_paused: boolean()}
  def settings, do: Settings.all()

  @doc """
  Flips one switch. `{:ok, settings}` with both switches as they now stand.
  """
  @spec put_setting(atom(), boolean(), actor()) :: {:ok, map()} | {:error, atom()}
  def put_setting(key, value, actor) do
    email = actor!(actor)

    cond do
      key not in Settings.keys() ->
        {:error, :unknown_setting}

      not is_boolean(value) ->
        {:error, :invalid_value}

      true ->
        transaction(fn ->
          {:ok, settings} = Settings.put(key, value, email)
          log!(email, "put_setting", "setting", Atom.to_string(key), %{value: value})
          settings
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Tournaments

  @doc """
  Tournaments, newest first. Filters: `status`, `installation_id`,
  `reported?` (only those with an open report), `search` (slug or name),
  `limit`, `offset`.
  """
  @spec list_tournaments(map() | keyword()) :: [Tournament.t()]
  def list_tournaments(filters \\ %{}) do
    filters = filters(filters, [:status, :installation_id, :reported?, :search, :limit, :offset])

    tournament_query()
    |> tournament_filter(:status, filters)
    |> tournament_filter(:installation_id, filters)
    |> tournament_filter(:reported?, filters)
    |> tournament_filter(:search, filters)
    |> QueryFilters.paginate(filters)
    |> Repo.all()
  end

  @doc "One tournament, with its installation preloaded, or `nil`."
  @spec get_tournament(String.t()) :: Tournament.t() | nil
  def get_tournament(slug) when is_binary(slug) do
    tournament_query()
    |> where([t], t.slug == ^slug)
    |> Repo.one()
    |> Repo.preload(:installation)
  end

  def get_tournament(_not_a_slug), do: nil

  defp tournament_query do
    latest =
      from s in Snapshot,
        group_by: s.tournament_slug,
        select: %{slug: s.tournament_slug, id: max(s.id)}

    open_reports =
      from r in Report,
        where: r.status == "open",
        group_by: r.tournament_slug,
        select: %{slug: r.tournament_slug, count: count(r.id)}

    from t in Tournament,
      as: :tournament,
      left_join: l in subquery(latest),
      on: l.slug == t.slug,
      left_join: s in Snapshot,
      as: :snapshot,
      on: s.id == l.id,
      left_join: r in subquery(open_reports),
      as: :reports,
      on: r.slug == t.slug,
      order_by: [desc: t.inserted_at, asc: t.slug],
      select_merge: %{
        name: fragment("json_extract(?, '$.tournament.name')", s.payload),
        last_published_at: s.received_at,
        open_reports: coalesce(r.count, 0)
      }
  end

  defp tournament_filter(query, :status, %{status: status}) when not is_nil(status),
    do: where(query, [tournament: t], t.status == ^to_string(status))

  defp tournament_filter(query, :installation_id, %{installation_id: id}) when is_binary(id),
    do: where(query, [tournament: t], t.installation_id == ^id)

  defp tournament_filter(query, :reported?, %{reported?: reported})
       when reported in [true, "true"],
       do: where(query, [reports: r], not is_nil(r.count))

  defp tournament_filter(query, :search, %{search: search})
       when is_binary(search) and search != "" do
    pattern = QueryFilters.like_pattern(search)

    where(
      query,
      [tournament: t, snapshot: s],
      fragment("? LIKE ? ESCAPE '\\'", t.slug, ^pattern) or
        fragment("json_extract(?, '$.tournament.name') LIKE ? ESCAPE '\\'", s.payload, ^pattern)
    )
  end

  defp tournament_filter(query, _key, _filters), do: query

  @doc "`pending` to `listed`."
  @spec approve(String.t(), actor()) :: {:ok, Tournament.t()} | {:error, atom()}
  def approve(slug, actor), do: set_status(slug, ["pending"], "listed", "approve", actor)

  @doc "`pending` or `listed` to `hidden`."
  @spec hide(String.t(), actor()) :: {:ok, Tournament.t()} | {:error, atom()}
  def hide(slug, actor), do: set_status(slug, ["pending", "listed"], "hidden", "hide", actor)

  @doc "`hidden` to `listed`."
  @spec unhide(String.t(), actor()) :: {:ok, Tournament.t()} | {:error, atom()}
  def unhide(slug, actor), do: set_status(slug, ["hidden"], "listed", "unhide", actor)

  defp set_status(slug, from_statuses, to, action, actor) do
    email = actor!(actor)

    result =
      transaction(fn ->
        case Tournaments.transition(slug, from_statuses, to) do
          {:ok, tournament} ->
            log!(email, action, "tournament", slug, %{from: from_statuses, to: to})
            tournament

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    # Once more after the commit, so the read path holds what was committed
    # rather than what the transaction saw.
    if is_binary(slug), do: Tournaments.forget(slug)
    result
  end

  @doc """
  Deletes everything held for a tournament - `OpenResults.Takedown.purge/1`.
  Idempotent, like the API route: `{:ok, counts}` even when nothing was there.
  """
  @spec delete(String.t(), actor()) :: {:ok, Takedown.counts()}
  def delete(slug, actor) when is_binary(slug) do
    email = actor!(actor)

    transaction(fn ->
      counts = Takedown.purge(slug)
      log!(email, "delete", "tournament", slug, counts)
      counts
    end)
    |> tap(fn _ -> Tournaments.forget(slug) end)
  end

  @doc """
  Rebinds a tournament to another installation and clears its stored
  tournament key, so that installation's next keyed publish claims it - what
  break-glass is used for today when an arbiter's laptop dies. Status is
  unchanged. Refused for a revoked target.
  """
  @spec transfer(String.t(), String.t(), actor()) :: {:ok, Tournament.t()} | {:error, atom()}
  def transfer(slug, installation_id, actor) do
    email = actor!(actor)

    case Repo.get(Installation, to_string(installation_id)) do
      nil ->
        {:error, :not_found}

      %Installation{status: "revoked"} ->
        {:error, :installation_revoked}

      %Installation{id: target} ->
        transaction(fn ->
          previous = Tournaments.get(slug)

          case Tournaments.transfer(slug, target) do
            {:ok, tournament} ->
              log!(email, "transfer", "tournament", slug, %{
                from: previous && previous.installation_id,
                to: target
              })

              tournament

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Installations

  @doc "Installations, newest first. Filters: `status`, `search`, `limit`, `offset`."
  @spec list_installations(map() | keyword()) :: [Installation.t()]
  def list_installations(filters \\ %{}) do
    filters |> filters([:status, :search, :limit, :offset]) |> Installations.list()
  end

  @doc "One installation, with its tournaments preloaded, or `nil`."
  @spec get_installation(String.t()) :: Installation.t() | nil
  def get_installation(id), do: Installations.get(id)

  @doc "`active` to `suspended`: may still delete its own tournaments, nothing else."
  @spec suspend(String.t(), actor()) :: {:ok, Installation.t()} | {:error, atom()}
  def suspend(id, actor),
    do: set_installation_status(id, ["active"], "suspended", "suspend", actor)

  @doc "`suspended` to `active`."
  @spec unsuspend(String.t(), actor()) :: {:ok, Installation.t()} | {:error, atom()}
  def unsuspend(id, actor),
    do: set_installation_status(id, ["suspended"], "active", "unsuspend", actor)

  @doc """
  Revokes an installation's key for good. `hide_tournaments: true` also hides
  every `pending` and `listed` tournament it holds; without it they stay as
  they are, and the key can still delete them.
  """
  @spec revoke(String.t(), actor(), keyword()) :: {:ok, Installation.t()} | {:error, atom()}
  def revoke(id, actor, opts) do
    email = actor!(actor)
    hide? = Keyword.get(opts, :hide_tournaments, false) == true

    result =
      transaction(fn ->
        case Installations.transition(to_string(id), ["active", "suspended"], "revoked") do
          {:ok, installation} ->
            hidden = if hide?, do: Tournaments.hide_all_for(installation.id), else: []

            log!(email, "revoke", "installation", installation.id, %{
              hide_tournaments: hide?,
              hidden: hidden
            })

            {installation, hidden}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {installation, hidden}} ->
        Enum.each(hidden, &Tournaments.forget/1)
        {:ok, Installations.get(installation.id)}

      error ->
        error
    end
  end

  defp set_installation_status(id, from_statuses, to, action, actor) do
    email = actor!(actor)

    transaction(fn ->
      case Installations.transition(to_string(id), from_statuses, to) do
        {:ok, installation} ->
          log!(email, action, "installation", installation.id, %{from: from_statuses, to: to})
          installation

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Reports

  @doc """
  Reports, newest first. `filters` is `:open`, `:resolved`, or a map/keyword
  with `status` (`open` | `resolved`), `slug`, `limit`, `offset`.
  """
  @spec list_reports(atom() | map() | keyword()) :: [Report.t()]
  def list_reports(status) when status in [:open, :resolved, "open", "resolved"],
    do: Reports.list(%{status: status})

  def list_reports(filters),
    do: filters |> filters([:status, :slug, :limit, :offset]) |> Reports.list()

  @doc "Marks a report resolved, with a free-text resolution."
  @spec resolve_report(term(), String.t() | atom(), actor()) ::
          {:ok, Report.t()} | {:error, atom()}
  def resolve_report(id, resolution, actor) do
    email = actor!(actor)
    resolution = resolution |> to_string() |> String.slice(0, 2000)

    transaction(fn ->
      case Reports.resolve(id, resolution, email) do
        {:ok, report} ->
          log!(email, "resolve_report", "report", Integer.to_string(report.id), %{
            slug: report.tournament_slug,
            resolution: resolution
          })

          report

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Address blocks

  @doc """
  Blocks an address or CIDR range from registration, minting and publishing
  until `expires_at` - which must be in the future and at most 30 days away.
  `{:error, changeset}` when it is not.
  """
  @spec block_address(String.t(), DateTime.t(), String.t(), actor()) ::
          {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def block_address(ip_or_cidr, expires_at, reason, actor) do
    email = actor!(actor)

    transaction(fn ->
      case AddressBlocks.create(ip_or_cidr, expires_at, reason, email) do
        {:ok, block} ->
          log!(email, "block_address", "address_block", Integer.to_string(block.id), %{
            cidr: block.cidr,
            expires_at: DateTime.to_iso8601(block.expires_at),
            reason: block.reason
          })

          block

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Every block that has not expired, soonest to expire first."
  @spec list_blocks() :: [Block.t()]
  def list_blocks, do: AddressBlocks.list_active()

  @doc "Lifts a block."
  @spec unblock(term(), actor()) :: {:ok, Block.t()} | {:error, :not_found}
  def unblock(id, actor) do
    email = actor!(actor)

    transaction(fn ->
      case AddressBlocks.get(id) do
        nil ->
          Repo.rollback(:not_found)

        block ->
          {:ok, block} = AddressBlocks.delete(block)

          log!(email, "unblock", "address_block", Integer.to_string(block.id), %{
            cidr: block.cidr
          })

          block
      end
    end)
  end

  @doc """
  How many installations registered from, or were last seen from, inside
  `ip_or_cidr` - what the panel shows before a block is confirmed. Addresses
  are forgotten after 30 days, so this counts the last month at most.
  """
  @spec installations_seen_from(String.t()) :: non_neg_integer()
  def installations_seen_from(ip_or_cidr), do: Installations.seen_from(ip_or_cidr)

  # ---------------------------------------------------------------------------
  # The log

  @doc """
  The action log, newest first. Filters: `actor`, `action`, `target_type`,
  `target`, `limit` (default 100), `offset`.
  """
  @spec list_actions(map() | keyword()) :: [Action.t()]
  def list_actions(filters \\ %{}) do
    filters =
      filters
      |> filters([:actor, :action, :target_type, :target, :limit, :offset])
      |> Map.put_new(:limit, 100)

    Enum.reduce([:actor, :action, :target_type, :target], from(a in Action), fn key, query ->
      case Map.get(filters, key) do
        nil -> query
        value -> where(query, [a], field(a, ^key) == ^to_string(value))
      end
    end)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> QueryFilters.paginate(filters)
    |> Repo.all()
  end

  @doc false
  # For `OpenResults.TournamentKeys`: a use of the operator token in the
  # tournament-key position. Never raises - an audit entry that failed to write
  # must not turn the recovery it records into a 500 - but logs if it fails.
  @spec log_break_glass(String.t(), atom(), String.t()) :: :ok
  def log_break_glass(slug, action, detail) do
    log!(@break_glass, "break_glass_#{action}", "tournament", slug, %{detail: detail})
    :ok
  rescue
    error ->
      Logger.error(
        "could not write the break-glass action log entry: #{Exception.message(error)}"
      )

      :ok
  end

  @doc false
  # For `OpenResults.Retention`.
  @spec log_retention(map()) :: :ok
  def log_retention(details) do
    log!(@retention, "retention", nil, nil, details)
    :ok
  end

  defp log!(actor, action, target_type, target, details) do
    Repo.insert!(%Action{
      actor: actor,
      action: action,
      target_type: target_type,
      target: target,
      details: stringify(details),
      inserted_at: DateTime.utc_now()
    })
  end

  # JSON round-trips string keys only; storing them that way means a row
  # reads back the same as it was written.
  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp actor!(%{email: email}) when is_binary(email) and email != "", do: email

  defp actor!(other) do
    raise ArgumentError, "a moderation actor is %{email: String.t()}, got: #{inspect(other)}"
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  # Filters arrive from a panel, so they may be a keyword list or a map, with
  # atom or string keys. Only the known keys survive, as atoms - never
  # `String.to_atom/1` on whatever was sent.
  defp filters(filters, allowed) when is_list(filters) or is_map(filters) do
    by_name = Map.new(allowed, &{Atom.to_string(&1), &1})

    Enum.reduce(filters, %{}, fn {key, value}, acc ->
      case key do
        key when is_atom(key) ->
          if key in allowed, do: Map.put(acc, key, value), else: acc

        key when is_binary(key) ->
          case Map.fetch(by_name, key) do
            {:ok, atom} -> Map.put(acc, atom, value)
            :error -> acc
          end

        _other ->
          acc
      end
    end)
  end

  defp filters(_nothing, _allowed), do: %{}
end
