defmodule OpenResults.Settings do
  @moduledoc """
  The runtime switches: `registration_open` and `public_publishing_paused`.

  Stored in the database rather than the environment because the operator has
  to be able to flip them from the admin panel on a Saturday morning without a
  restart - a restart that would also drop every rendered page the cache holds
  in the middle of an event.

  A switch with no row reads as its documented default, which is `false` for
  both. So a server that has never been touched is closed to new
  installations, and is not paused - which only matters once registration has
  been opened, since nobody holds an installation key before that.

  Read from the database on every call. They are consulted on registration,
  minting, publishing with an installation key and `GET /api/server`, none of
  which is the read path a hall full of phones is hitting, and a cache here
  would be one more thing that could disagree with the panel.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Repo
  alias OpenResults.Settings.Setting

  @defaults %{registration_open: false, public_publishing_paused: false}

  @type key :: :registration_open | :public_publishing_paused
  @type t :: %{registration_open: boolean(), public_publishing_paused: boolean()}

  @doc "The switches this server has."
  @spec keys() :: [key()]
  def keys, do: Map.keys(@defaults)

  @doc "Every switch, with defaults filled in."
  @spec all() :: t()
  def all do
    stored =
      from(s in Setting, where: s.key in ^Enum.map(keys(), &Atom.to_string/1))
      |> Repo.all()
      |> Map.new(&{String.to_existing_atom(&1.key), &1.value})

    Map.merge(@defaults, stored)
  end

  @doc "One switch."
  @spec get(key()) :: boolean()
  def get(key) when is_map_key(@defaults, key) do
    case Repo.get(Setting, Atom.to_string(key)) do
      nil -> Map.fetch!(@defaults, key)
      %Setting{value: value} -> value
    end
  end

  @doc """
  Sets one switch. `updated_by` is recorded on the row; the action log is
  `OpenResults.Moderation`'s job, which is the only caller that should be
  flipping these.
  """
  @spec put(key(), boolean(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def put(key, value, updated_by) when is_map_key(@defaults, key) and is_boolean(value) do
    now = DateTime.utc_now()

    %Setting{key: Atom.to_string(key)}
    |> Setting.changeset(%{value: value, updated_by: updated_by})
    |> Ecto.Changeset.put_change(:inserted_at, now)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Repo.insert(
      on_conflict: [set: [value: value, updated_by: updated_by, updated_at: now]],
      conflict_target: :key
    )
    |> case do
      {:ok, _setting} -> {:ok, all()}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
