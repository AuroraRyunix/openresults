defmodule OpenResults.Federations.BEL.Config do
  @moduledoc """
  Whether this deployment relays the Belgian (KBSB/FRBE) national roster to
  OpenPairings desktop installs - see docs/federations-bel.md.

  ## Optional, off by default

  `OPENRESULTS_KBSB_API_URL` and `OPENRESULTS_KBSB_API_KEY` (both, or
  neither - a half-configured pair is refused at boot the same way
  `FIDE_LOOKUP_ENDPOINT`/`FIDE_LOOKUP_TOKEN` are, see `config/runtime.exs`).
  Unset, `enabled?/0` is false: the sync never runs, the admin panel shows
  "not configured", and `GET /api/federations/bel/players` answers 404
  `not_configured` rather than an empty list - an empty list would look like
  a relay that ran and found nothing, which is a different situation from
  one that was never turned on.

  These are deliberately separate from `KBSB_API_URL`/`KBSB_API_KEY` on the
  hosted OpenPairings server: two different processes, on two different
  machines in general, each holding its own copy of the same key so that
  revoking one does not need the other to change.
  """

  @doc "Whether both the base URL and the API key are configured."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(api_url()) and not is_nil(api_key())

  @doc "The KBSB data platform's base URL, or nil."
  def api_url, do: blank_to_nil(Application.get_env(:openresults, :bel_kbsb_api_url))

  @doc "The KBSB data platform's API key, or nil."
  def api_key, do: blank_to_nil(Application.get_env(:openresults, :bel_kbsb_api_key))

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v
end
