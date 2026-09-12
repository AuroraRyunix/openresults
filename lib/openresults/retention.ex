defmodule OpenResults.Retention do
  @moduledoc """
  What public publishing keeps, and for how long.

  Three things, each thirty days, each for its own reason:

    * **client addresses** - on installations (where one registered, where it
      was last seen) and on reports. They exist so an operator can judge an
      address block; after a month they are only personal data. Each is
      measured from its own timestamp, so an installation still in use keeps
      its last-seen address while its registration address goes.
    * **minted slugs that never published** - a slug is minted before the
      first publish, and an installation that minted and walked away should
      not hold a place in its own tournament limit, or a name, for ever.
    * **expired address blocks** - already ignored by every check; this only
      takes them out of the panel's list.

  Run once a day by `OpenResults.Retention.Scheduler`. The functions take
  `now` so a test can call them with a clock rather than wait for one.
  """

  alias OpenResults.AddressBlocks
  alias OpenResults.Installations
  alias OpenResults.Moderation
  alias OpenResults.Reports
  alias OpenResults.Tournaments

  @days 30

  @doc "How long, in days, each of the three is kept."
  def days, do: @days

  @doc """
  Runs all three and writes one `retention` entry to the action log when
  anything changed. Returns the counts.
  """
  @spec run(DateTime.t()) :: %{
          addresses_nulled: non_neg_integer(),
          slugs_released: [String.t()],
          blocks_removed: non_neg_integer()
        }
  def run(now \\ DateTime.utc_now()) do
    result = %{
      addresses_nulled: null_old_addresses(now),
      slugs_released: release_unpublished_slugs(now),
      blocks_removed: remove_expired_blocks(now)
    }

    if result.addresses_nulled > 0 or result.slugs_released != [] or result.blocks_removed > 0 do
      Moderation.log_retention(result)
    end

    result
  end

  @doc "Nulls installation and report addresses older than thirty days."
  @spec null_old_addresses(DateTime.t()) :: non_neg_integer()
  def null_old_addresses(now \\ DateTime.utc_now()) do
    cutoff = cutoff(now)
    Installations.null_addresses_before(cutoff) + Reports.null_addresses_before(cutoff)
  end

  @doc "Releases slugs minted more than thirty days ago that never published."
  @spec release_unpublished_slugs(DateTime.t()) :: [String.t()]
  def release_unpublished_slugs(now \\ DateTime.utc_now()) do
    now |> cutoff() |> Tournaments.release_unpublished_before()
  end

  @doc "Deletes address blocks whose expiry has passed."
  @spec remove_expired_blocks(DateTime.t()) :: non_neg_integer()
  def remove_expired_blocks(now \\ DateTime.utc_now()), do: AddressBlocks.remove_expired(now)

  defp cutoff(now), do: DateTime.add(now, -@days * 86_400, :second)
end
