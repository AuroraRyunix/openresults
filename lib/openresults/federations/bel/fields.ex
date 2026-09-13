defmodule OpenResults.Federations.BEL.Fields do
  @moduledoc """
  The one and only allowlist of fields that leave this server about a
  Belgian (KBSB/FRBE) player, and the reason there is exactly one.

  `OpenResults.Federations.BEL.Sync` reduces every row the KBSB data
  platform's `/api/v1/players_national/export` returns through `reduce/1`
  before it is ever written to the store `OpenResultsWeb.Federations.
  BelController` serves. Nothing that does not appear in `@allowed` below
  can reach a desktop OpenPairings install through this relay, no matter
  what the upstream export adds later - a new column on the KBSB side is
  silently dropped here, not silently forwarded.

  ## Why this list and not another

  These are the fields KBSB already prints on its own public rating lists:
  a player's name, their national ("matricule") id, national rating, club
  number and name, FIDE id, and federation. Nothing else - **never** a
  birth date or birth year, an email address, a postal address or a phone
  number, even on a KBSB export that happens to carry one. Anything the
  export marks as internal bookkeeping (whether a member has died, whether
  they are currently affiliated) stops here too: it answers a question this
  relay was never asked to answer, and it is not printed on a public list.

  `PairingsEngine.Federations.BEL.Member` and `.Parser` are what OpenPairings
  actually reads a synced row into - checked against both before writing
  this list, and again every time either one changes what it consumes.
  There is deliberately no field here OpenPairings does not use, and no
  field OpenPairings uses that is missing here.
  """

  @allowed [
    :national_id,
    :last_name,
    :first_name,
    :national_rating,
    :fide_id,
    :club_number,
    :club_name,
    :federation
  ]

  @doc "The fields a reduced row may carry - the allowlist itself, for tests."
  def allowed, do: @allowed

  @doc """
  Reduces one raw player map from the KBSB data platform export into a map
  with only `allowed/0`'s keys, as atoms, ready to be stored and served.

  Accepts either string or atom keys from the source (the export uses
  string keys; `national_id` is coerced to a string, matching how
  `PairingsEngine.Federations.BEL.Member` keys its own mirror). A key not in
  `allowed/0` is dropped, whatever the source calls it and whatever it
  contains.
  """
  @spec reduce(map()) :: map()
  def reduce(%{} = raw) do
    get = fn key -> raw[to_string(key)] || raw[key] end

    %{
      national_id: get.(:national_id) |> to_id_string(),
      last_name: get.(:last_name) || "",
      first_name: get.(:first_name) || "",
      national_rating: get.(:national_rating),
      fide_id: get.(:fide_id),
      club_number: club_number(get.(:club_number) || get.(:club)),
      club_name: get.(:club_name) || "",
      federation: get.(:federation) || get.(:fed) || ""
    }
  end

  defp to_id_string(nil), do: nil
  defp to_id_string(id), do: to_string(id)

  # `0` is the platform's "no club" sentinel, same treatment as
  # `PairingsEngine.Federations.BEL.Api.club_number/1` - never forwarded as a
  # literal club number.
  defp club_number(0), do: nil
  defp club_number(n), do: n
end
