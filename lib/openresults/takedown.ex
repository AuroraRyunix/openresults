defmodule OpenResults.Takedown do
  @moduledoc """
  Removing everything this server holds for one tournament.

  A published tournament carries player names, ratings, clubs and federations,
  and its registration queue carries email addresses. Until this existed the
  only way to take any of that down was to SSH in and edit SQLite by hand,
  which is not a takedown process - it is the absence of one.

  ## Why it is a module and not a `delete_all`

  Because the obvious implementation is wrong in a way that LOOKS right.

  `snapshots` is append-only: every publish is its own row, and
  `GET /api/tournaments/:slug/history?at=` serves whichever row was current at
  an instant. Deleting the current snapshot therefore removes the tournament
  from every public page, returns 404 everywhere a person would look, and
  leaves every earlier row - names, ratings, federations, and any round or
  board the arbiter had already retracted - one query away for anyone holding
  the ingest token. It would report success and satisfy a spot check.

  A takedown that leaves history behind is worse than no takedown, because
  somebody believes it worked. So this deletes EVERY row for the slug across
  every table: all snapshots, the registration queue, and the key claim.

  ## Why the key goes too

  A takedown means the slug is gone, not sealed. Keeping the claim would stop
  the arbiter republishing under the same name with a fresh key after the
  laptop that held the old one died - the exact situation a takedown often
  follows. The slug returns to unclaimed and the next publish claims it again,
  by the same trust-on-first-use path as any other new slug.

  ## One transaction

  A purge that removed the snapshots and then failed would leave a registration
  queue - the email addresses - attached to a tournament that no longer exists
  and can no longer be found to retry. All or nothing.
  """

  alias OpenResults.Registrations
  alias OpenResults.Repo
  alias OpenResults.Snapshots
  alias OpenResults.TournamentKeys

  @type counts :: %{
          snapshots: non_neg_integer(),
          registrations: non_neg_integer(),
          key: non_neg_integer()
        }

  @doc """
  Deletes everything held for `slug` and reports what went.

  Idempotent, and the counts are why it can afford to be: purging a slug that
  holds nothing is not an error, it is a no-op that truthfully reports three
  zeroes. A caller retrying after a timeout gets the same "it is gone" as the
  call that did the work, while a caller who mistyped the slug can still see
  from the counts that it removed nothing.
  """
  @spec purge(String.t()) :: counts()
  def purge(slug) do
    {:ok, counts} =
      Repo.transaction(fn ->
        # Each context deletes its own rows. The alternative - one query per
        # table written here - would put `snapshots` and `registrations` schema
        # knowledge in a third place that has no other reason to know it.
        %{
          snapshots: Snapshots.delete_all_for(slug),
          registrations: Registrations.delete_all_for(slug),
          key: TournamentKeys.release(slug)
        }
      end)

    counts
  end
end
