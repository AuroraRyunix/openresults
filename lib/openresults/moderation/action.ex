defmodule OpenResults.Moderation.Action do
  @moduledoc """
  One entry in the action log: who did what to which target, and when.

  `actor` is an admin's email address, `break-glass` for a use of the operator
  token in a tournament-key header, `retention` for the daily job,
  `installation:<id>`, `tournament-key` or `operator-token` for a tournament
  deleted through the API by that credential, or
  `restore-replay` for an action a restored backup had undone and the boot
  applied again from `OpenResults.ModerationJournal` (its `details` carry the
  original action's time as `journal_at`).
  Append-only - nothing in this app deletes one of these, and the only update
  is retention forgetting the `cidr` in an address-block entry
  (`OpenResults.Moderation.forget_expired_block_addresses/2`).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "moderation_actions" do
    field :actor, :string
    field :action, :string
    field :target_type, :string
    field :target, :string
    field :details, :map, default: %{}

    field :inserted_at, :utc_datetime_usec
  end
end
