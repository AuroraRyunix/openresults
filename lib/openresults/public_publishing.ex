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

  The limits, the operator's name and the terms link come from
  `OpenResults.ServerSettings`: a value saved in the admin panel, else the
  environment's, else the default - an ETS read, never a query per request.
  An installation may carry its own four limits (`installation_limits/1`),
  which win over the server's for that installation alone.
  """

  alias OpenResults.ServerSettings
  alias OpenResults.Settings

  @doc "Is public publishing enabled on this server? The environment gate."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:openresults, :public_publishing, false) == true

  @doc "Registrations one client address may make per 24 hours."
  def registrations_per_address, do: ServerSettings.get(:registrations_per_address)

  @doc "Registrations the whole server accepts per 24 hours."
  def registrations_per_day, do: ServerSettings.get(:registrations_per_day)

  @doc """
  Mints and publishes one installation may make per minute: its own limit
  when it has one, otherwise the server's.
  """
  def installation_publishes_per_minute(installation \\ nil),
    do: own(installation, :publishes_per_minute, :installation_publishes_per_minute)

  @doc "`pending` plus `listed` tournaments one installation may hold."
  def installation_max_tournaments(installation \\ nil),
    do: own(installation, :max_tournaments, :installation_max_tournaments)

  @doc "The largest snapshot body, in bytes, an installation key may publish."
  def installation_max_snapshot_bytes(installation \\ nil),
    do: own(installation, :max_snapshot_bytes, :installation_max_snapshot_bytes)

  @doc """
  How many stored versions a tournament owned by an installation keeps - see
  `OpenResults.Snapshots.prune_versions/2`. Never less than 1, whatever the
  configuration says: the newest version is the one the public reads, and a
  cap of 0 would prune it. `config/runtime.exs` and the panel both refuse
  such a value; this is the last line.
  """
  def installation_max_versions(installation \\ nil),
    do: max(own(installation, :max_versions, :installation_max_versions), 1)

  @doc """
  The free space, as a whole percentage of the database's volume, below which
  installation keys are refused `storage_low` on mint and publish. `0` is off.
  See `OpenResults.DiskSpace`.
  """
  def min_free_disk_percent, do: min(ServerSettings.get(:min_free_disk_percent), 100)

  @doc """
  Each of an installation's four limits: `%{limit => %{value: n, own: n | nil}}`,
  `own` being the installation's override and `value` the one in force. For
  the admin panel.
  """
  @spec installation_limits(OpenResults.Installations.Installation.t()) :: map()
  def installation_limits(installation) do
    %{
      max_tournaments: limit(installation, :max_tournaments, &installation_max_tournaments/1),
      max_snapshot_bytes:
        limit(installation, :max_snapshot_bytes, &installation_max_snapshot_bytes/1),
      publishes_per_minute:
        limit(installation, :publishes_per_minute, &installation_publishes_per_minute/1),
      max_versions: limit(installation, :max_versions, &installation_max_versions/1)
    }
  end

  @doc """
  The global setting an installation's own limit overrides - and whose range
  it is validated against.
  """
  def global_for(:max_tournaments), do: :installation_max_tournaments
  def global_for(:max_snapshot_bytes), do: :installation_max_snapshot_bytes
  def global_for(:publishes_per_minute), do: :installation_publishes_per_minute
  def global_for(:max_versions), do: :installation_max_versions

  defp limit(installation, field, fun),
    do: %{value: fun.(installation), own: Map.get(installation, field)}

  # An installation's own value, when it has one; the server's otherwise.
  defp own(%{} = installation, field, global) do
    case Map.get(installation, field) do
      value when is_integer(value) -> value
      _blank -> ServerSettings.get(global)
    end
  end

  defp own(nil, _field, global), do: ServerSettings.get(global)

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
      operator: ServerSettings.get(:operator_name),
      terms_url: ServerSettings.get(:terms_url),
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
end
