defmodule OpenResults.PublicPublishing do
  @moduledoc """
  Whether this server lets any OpenPairings installation publish, and the
  numbers that bound it. The contract is `docs/public-publishing.md`.

  Two layers, and they answer different questions:

  | | where | changed by | answers |
  |---|---|---|---|
  | the environment gate | `OPENRESULTS_PUBLIC_PUBLISHING=enabled` | a restart | does this feature exist on this server at all |
  | the runtime switches | `OpenResults.Settings` | the admin panel | is it currently taking new installations, and publishes |

  The gate is off by default and that is the design, not caution: a club that
  runs OpenResults beside its own website upgrades and must find nothing new
  reachable. With it off, `/api/installations` and `/api/tournaments` do not
  exist (the same 404 as a path nobody routed), an installation key is just an
  unknown token, and `GET /api/server` says `unavailable`.

  The limits are read from application config on every call rather than at
  compile time, so a test can move one and so `config/runtime.exs` can supply
  them from the environment.
  """

  alias OpenResults.Settings

  @doc "Is public publishing enabled on this server? The environment gate."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:openresults, :public_publishing, false) == true

  @doc "Registrations one client address may make per 24 hours."
  def registrations_per_address, do: env(:registrations_per_address, 10)

  @doc "Registrations the whole server accepts per 24 hours."
  def registrations_per_day, do: env(:registrations_per_day, 200)

  @doc "Mints and publishes one installation may make per minute."
  def installation_publishes_per_minute, do: env(:installation_publishes_per_minute, 30)

  @doc "`pending` plus `listed` tournaments one installation may hold."
  def installation_max_tournaments, do: env(:installation_max_tournaments, 50)

  @doc "The largest snapshot body, in bytes, an installation key may publish."
  def installation_max_snapshot_bytes, do: env(:installation_max_snapshot_bytes, 3_145_728)

  @doc """
  How many stored versions a tournament owned by an installation keeps - see
  `OpenResults.Snapshots.prune_versions/2`. Never less than 1, whatever the
  configuration says: the newest version is the one the public reads, and a
  cap of 0 would prune it. `config/runtime.exs` refuses such a value at boot;
  this is the second line.
  """
  def installation_max_versions, do: max(env(:installation_max_versions, 20), 1)

  @doc """
  The free space, as a whole percentage of the database's volume, below which
  installation keys are refused `storage_low` on mint and publish. `0` is off.
  See `OpenResults.DiskSpace`.
  """
  def min_free_disk_percent, do: min(env(:min_free_disk_percent, 10), 100)

  @doc """
  What `GET /api/server` answers.

  The two state fields collapse to `unavailable` whenever the gate is off,
  whatever the switches in the database say: a switch that was flipped while
  the feature existed must not make it look available after it was switched
  off at the environment.
  """
  @spec server_info() :: map()
  def server_info do
    settings = Settings.all()

    %{
      name: "OpenResults",
      version: OpenResults.Build.version(),
      operator: blank_to_nil(Application.get_env(:openresults, :operator_name)),
      terms_url: blank_to_nil(Application.get_env(:openresults, :terms_url)),
      public_registration: registration_state(settings),
      public_publishing: publishing_state(settings)
    }
  end

  defp registration_state(settings) do
    cond do
      not enabled?() -> "unavailable"
      settings.registration_open -> "open"
      true -> "closed"
    end
  end

  defp publishing_state(settings) do
    cond do
      not enabled?() -> "unavailable"
      settings.public_publishing_paused -> "paused"
      true -> "active"
    end
  end

  defp env(key, default) do
    case Application.get_env(:openresults, key) do
      value when is_integer(value) and value >= 0 -> value
      _unset -> default
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_absent), do: nil
end
