defmodule OpenResults.Moderation.Action do
  @moduledoc """
  One entry in the action log: who did what to which target, and when.

  `actor` is an admin's email address, `break-glass` for a use of the operator
  token in a tournament-key header, `retention` for the daily job, or
  `restore-replay` for an action a restored backup had undone and the boot
  applied again from `OpenResults.ModerationJournal` (its `details` carry the
  original action's time as `journal_at`).
  Append-only - nothing in this app updates or deletes one of these.
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
