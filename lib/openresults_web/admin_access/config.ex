defmodule OpenResultsWeb.AdminAccess.Config do
  @moduledoc """
  What the admin gate is configured to accept, read fresh on every request.

  Three values, all from the environment through `config/runtime.exs`:

  | Application env | Variable |
  |---|---|
  | `:admin_access_team_domain` | `OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN` |
  | `:admin_access_aud` | `OPENRESULTS_ADMIN_ACCESS_AUD` |
  | `:admin_emails` | `OPENRESULTS_ADMIN_EMAILS` |

  **All three or nothing.** A value that is missing, empty, or unusable (a
  team domain that is not a host name, an email list with no emails in it)
  counts as unset, and one unset value switches the whole panel off. There is
  no partial mode: a gate that checked the audience but not the email list, or
  the other way round, is exactly the "mistaken configuration equals an open
  admin" this panel is built to rule out.

  ## The development bypass

  `config :openresults, :admin_dev_bypass, email: "..."` lets `/admin` be
  used on a laptop with no Cloudflare in front of it. It is honoured only when
  the configured `:environment` is `:dev` or `:test`, it is never read from
  an environment variable, and `check_boot!/0` refuses to start a production
  node that has it set at all - see `OpenResults.Application`.
  """

  require Logger

  @enforce_keys [:team_domain, :issuer, :audience, :emails]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          team_domain: String.t(),
          issuer: String.t(),
          audience: String.t(),
          emails: MapSet.t(String.t())
        }

  # A host name and nothing else: labels of letters, digits and hyphens,
  # at least one dot. What is left after the scheme and trailing slashes are
  # stripped must look like this, or the value is treated as unset - it is
  # about to become both the issuer we trust and a URL we fetch keys from, so
  # "mostly a host name" is not good enough.
  @host ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/

  @doc """
  The gate's configuration, or `:unconfigured` when any of the three values
  is missing or unusable.
  """
  @spec fetch() :: {:ok, t()} | :unconfigured
  def fetch do
    with {:ok, domain} <-
           team_domain(Application.get_env(:openresults, :admin_access_team_domain)),
         {:ok, audience} <- present(Application.get_env(:openresults, :admin_access_aud)),
         {:ok, emails} <- emails(Application.get_env(:openresults, :admin_emails)) do
      {:ok,
       %__MODULE__{
         team_domain: domain,
         issuer: "https://" <> domain,
         audience: audience,
         emails: emails
       }}
    else
      _unset -> :unconfigured
    end
  end

  @doc """
  The team domain as a bare, lower-case host name.

  Accepted with or without a scheme and with or without a trailing slash,
  because the dashboard shows it both ways and either is an honest thing to
  paste: `myteam.cloudflareaccess.com`, `https://myteam.cloudflareaccess.com/`.
  """
  @spec team_domain(term()) :: {:ok, String.t()} | :error
  def team_domain(value) when is_binary(value) do
    host =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\Ahttps?:\/\//, "")
      |> String.trim_trailing("/")

    if Regex.match?(@host, host), do: {:ok, host}, else: :error
  end

  def team_domain(_value), do: :error

  @doc """
  The allowed emails: comma separated, trimmed, compared case-insensitively.
  """
  @spec emails(term()) :: {:ok, MapSet.t(String.t())} | :error
  def emails(value) when is_binary(value) do
    emails =
      value
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(emails) == 0, do: :error, else: {:ok, emails}
  end

  def emails(_value), do: :error

  @doc "Whether `email` - a claim, as it arrived - is one of the allowed ones."
  @spec allowed?(t(), term()) :: boolean()
  def allowed?(%__MODULE__{emails: emails}, email) when is_binary(email),
    do: MapSet.member?(emails, email |> String.trim() |> String.downcase())

  def allowed?(%__MODULE__{}, _no_email), do: false

  @doc """
  The email the development bypass signs in as, or `:off`.

  `:off` in any environment but `:dev` and `:test`, whatever the configuration
  says. `check_boot!/0` already refuses to start production with it set; this
  is the second lock, for a value put in place on a running node.
  """
  @spec dev_bypass() :: {:ok, String.t()} | :off
  def dev_bypass do
    with env when env in [:dev, :test] <- environment(),
         {:ok, email} <- bypass_email(Application.get_env(:openresults, :admin_dev_bypass)) do
      {:ok, email}
    else
      _ -> :off
    end
  end

  @doc """
  Refuses to boot a production node with the development bypass configured.

  Called first thing in `OpenResults.Application.start/2`. A bypass that
  reached production would be an admin panel open to anyone who can reach
  the page, so this is a crash at boot with the reason on the first line of
  the log, not a warning somebody might read later.

  An `:environment` that is not configured at all counts as production: the
  guard fails closed.
  """
  @spec check_boot!(atom(), term()) :: :ok
  def check_boot!(
        env \\ environment(),
        bypass \\ Application.get_env(:openresults, :admin_dev_bypass)
      ) do
    if env not in [:dev, :test] and not is_nil(bypass) and bypass != false do
      raise """
      refusing to start: the admin panel's development bypass is configured \
      (config :openresults, :admin_dev_bypass) in the #{inspect(env)} environment.

      The bypass signs anyone who reaches /admin in without Cloudflare Access. \
      It belongs in config/dev.exs or config/test.exs only. Remove it from \
      whichever config file set it for this environment, then start again.
      """
    end

    :ok
  end

  @doc """
  Logs, once at boot, a configuration that is half there.

  None of the three set is the ordinary state of a club's own copy and says
  nothing. One or two set is always a mistake, and the symptom - every
  `/admin` path answering 404 - is deliberately silent on the page, so it is
  said here instead.
  """
  @spec log_boot_state() :: :ok
  def log_boot_state do
    checks = [
      {"OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN",
       team_domain(Application.get_env(:openresults, :admin_access_team_domain))},
      {"OPENRESULTS_ADMIN_ACCESS_AUD",
       present(Application.get_env(:openresults, :admin_access_aud))},
      {"OPENRESULTS_ADMIN_EMAILS", emails(Application.get_env(:openresults, :admin_emails))}
    ]

    missing = for {name, :error} <- checks, do: name

    cond do
      dev_bypass() != :off ->
        Logger.warning("admin panel: development bypass is ON - /admin skips Cloudflare Access")

      missing == [] ->
        Logger.info("admin panel: enabled behind Cloudflare Access")

      length(missing) == length(checks) ->
        :ok

      true ->
        Logger.warning(
          "admin panel: OFF, every /admin path answers 404 - missing or unusable: " <>
            Enum.join(missing, ", ")
        )
    end

    :ok
  end

  # Set in config/config.exs from `config_env()`. Absent reads as production,
  # so everything that asks "is this dev?" fails closed.
  defp environment, do: Application.get_env(:openresults, :environment, :prod)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp present(_value), do: :error

  defp bypass_email(opts) when is_list(opts) do
    case Keyword.get(opts, :email) do
      email when is_binary(email) and email != "" -> {:ok, email}
      _ -> :error
    end
  end

  defp bypass_email(_value), do: :error
end
