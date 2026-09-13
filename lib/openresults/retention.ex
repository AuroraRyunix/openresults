defmodule OpenResults.Retention do
  @moduledoc """
  What public publishing keeps, and for how long.

  Six things, each for its own reason:

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
    * **registrations** - the entry queue, email addresses included, once the
      tournament has been over for `OPENRESULTS_REGISTRATION_RETENTION_DAYS`
      (default 30). See `OpenResults.Registrations.delete_expired/2`.
    * **report contact emails** - once the report has been resolved for
      `OPENRESULTS_REPORT_CONTACT_RETENTION_DAYS` (default 90). An open report
      keeps its contact.
    * **address ranges in the action log** - a `block_address` or `unblock`
      entry forgets its `cidr` once the block has been over for
      `OPENRESULTS_BLOCK_ADDRESS_RETENTION_DAYS` (default 30).

  The first three are thirty days, fixed. `docs/privacy-retention.md` has the
  whole table, backups included.

  Run once a day by `OpenResults.Retention.Scheduler`. The functions take
  `now` so a test can call them with a clock rather than wait for one.
  """

  alias OpenResults.AddressBlocks
  alias OpenResults.Installations
  alias OpenResults.Moderation
  alias OpenResults.Registrations
  alias OpenResults.Reports
  alias OpenResults.Tournaments

  @days 30

  @doc "How long, in days, each of the first three is kept."
  def days, do: @days

  @doc "Days after a tournament ends that its registrations are kept."
  def registration_retention_days,
    do: Application.get_env(:openresults, :registration_retention_days, 30)

  @doc "Days after a report is resolved that its contact email is kept."
  def report_contact_retention_days,
    do: Application.get_env(:openresults, :report_contact_retention_days, 90)

  @doc "Days after an address block ends that the action log keeps its range."
  def block_address_retention_days,
    do: Application.get_env(:openresults, :block_address_retention_days, 30)

  @doc """
  Runs all six and writes one `retention` entry to the action log when
  anything changed. Returns the counts.
  """
  @spec run(DateTime.t()) :: %{
          addresses_nulled: non_neg_integer(),
          slugs_released: [String.t()],
          blocks_removed: non_neg_integer(),
          registrations_deleted: non_neg_integer(),
          report_contacts_forgotten: non_neg_integer(),
          block_addresses_forgotten: non_neg_integer()
        }
  def run(now \\ DateTime.utc_now()) do
    result = %{
      addresses_nulled: null_old_addresses(now),
      slugs_released: release_unpublished_slugs(now),
      blocks_removed: remove_expired_blocks(now),
      registrations_deleted: delete_expired_registrations(now),
      report_contacts_forgotten: forget_old_report_contacts(now),
      block_addresses_forgotten: forget_expired_block_addresses(now)
    }

    if result.addresses_nulled > 0 or result.slugs_released != [] or result.blocks_removed > 0 or
         result.registrations_deleted > 0 or result.report_contacts_forgotten > 0 or
         result.block_addresses_forgotten > 0 do
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

  @doc "Deletes the registrations of tournaments over for the retention window."
  @spec delete_expired_registrations(DateTime.t()) :: non_neg_integer()
  def delete_expired_registrations(now \\ DateTime.utc_now()),
    do: Registrations.delete_expired(now, registration_retention_days())

  @doc "Nulls the contact email of reports resolved longer ago than the window."
  @spec forget_old_report_contacts(DateTime.t()) :: non_neg_integer()
  def forget_old_report_contacts(now \\ DateTime.utc_now()) do
    now
    |> DateTime.add(-report_contact_retention_days() * 86_400, :second)
    |> Reports.null_contact_emails_before()
  end

  @doc "Forgets the address range in action-log entries for blocks long over."
  @spec forget_expired_block_addresses(DateTime.t()) :: non_neg_integer()
  def forget_expired_block_addresses(now \\ DateTime.utc_now()),
    do: Moderation.forget_expired_block_addresses(now, block_address_retention_days())

  defp cutoff(now), do: DateTime.add(now, -@days * 86_400, :second)
end
