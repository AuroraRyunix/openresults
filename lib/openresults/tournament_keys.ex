defmodule OpenResults.TournamentKeys do
  @moduledoc """
  Which machine is allowed to touch which tournament.

  There are two questions on the write path and they are not the same
  question:

  | | asked by | answers |
  |---|---|---|
  | the ingest token | `OpenResultsWeb.Plugs.IngestAuth` | may this machine talk to this server at all |
  | the tournament key | this module | may it touch THIS tournament |

  Before this existed there was only the first one, which meant a single
  shared secret let anything holding it overwrite any tournament on the
  server, including one it had never published - and, once the delete route
  arrived, remove one. Publishing rights over `gent-spring-open-2026` and
  publishing rights over somebody else's event are different grants, so they
  are now different secrets.

  ## Trust on first use

  The arbiter's machine generates a random key per tournament and sends it
  with the first publish. That publish CLAIMS the slug: the digest is stored
  and every later publish, and any delete, must present the same key.

  This is TOFU, with everything TOFU implies - the server takes the first
  claimant's word for it, because at that moment there is nothing else to
  check it against. Two reasons that is the right trade here rather than a
  hole:

  1. **The first question is already answered.** Nothing reaches this module
     without the server-wide ingest token, so the claimant is not the public;
     it is a machine an operator deliberately configured. The exposure this
     guards is ACCIDENT - two arbiters' laptops picking the same obvious slug
     for two different events, one silently flattening the other - rather
     than attack.
  2. **The alternative is an account system.** Verifying a claim needs an
     identity to verify it against, and this app deliberately has no accounts,
     no sessions and no cookies. Adding them so that a slug could be
     pre-registered would cost the whole read-side design to close a gap the
     ingest token already narrows to configured machines.

  ## A publish carrying no key

  Allowed, and the slug simply stays unclaimed.

  This is the additive-only rule from `docs/snapshot-schema.md` applied to
  authentication instead of to fields. Snapshots already exist in
  production-shaped databases from before any of this, so slugs exist that
  have published for a season and have no key; and OpenPairings laptops in the
  field will not learn to send one until their arbiters update, which they do
  when they feel like it. Refusing a keyless publish would take those
  tournaments off the air mid-event, and the arbiter would find out in the
  hall.

  So there is no backfill and no admin step. **A legacy slug is adopted by the
  first publish that carries a key** - the same TOFU path a brand-new slug
  takes, which is why there is only one path. Until that happens the slug
  behaves exactly as it did before this module existed.

  The protection is not weakened by that, because claiming is one-way: once a
  slug HAS a key, a keyless publish to it is refused (`:key_required`). An old
  client cannot take a claimed tournament over by simply omitting the header,
  which would otherwise make the whole thing decorative. The cost is that an
  arbiter who claims a slug and then DOWNGRADES to a client that cannot send
  keys is locked out - deliberately, and that is what break-glass is for.

  ## Break-glass

  A key lives on one laptop. Laptops die, and a tournament whose key died with
  it would be unpublishable and undeletable forever, which is a worse failure
  than the one this module prevents.

  So a request may present the SERVER-WIDE INGEST TOKEN in the tournament-key
  position and the key check is overridden. That is a deliberate act - an
  operator has to go and paste the server's master secret where a per-event
  secret belongs - so it cannot happen by accident, and it grants nothing the
  token holder could not already do by editing the database by hand. Every use
  is logged at warning level with the slug and the action.

  Break-glass never claims a slug. Storing a hash of the server-wide token as
  a tournament key would quietly promote the master secret into a per-event
  one, and then rotating the ingest token would lock out every tournament
  claimed that way.
  """

  import Ecto.Query, warn: false

  require Logger

  alias OpenResults.Repo
  alias OpenResults.TournamentKeys.TournamentKey

  @type error :: :key_required | :key_mismatch
  @type outcome :: :ok | {:error, error()}

  @doc """
  May this request publish to `slug`?

  Writes, on the one path that is allowed to: an unclaimed slug presented with
  a key is claimed here. Everything else is a read.
  """
  @spec authorize_publish(String.t(), String.t() | nil) :: outcome()
  def authorize_publish(slug, presented), do: authorize(slug, presented, :publish)

  @doc """
  May this request delete `slug`?

  Identical to `authorize_publish/2` except that it never claims. Claiming a
  slug on the way to destroying it would leave a key row pointing at nothing,
  and `OpenResults.Takedown.purge/1` would only have to delete it again.

  An UNCLAIMED slug can be deleted by anyone holding the ingest token, which
  is the same authority that could already overwrite it into an empty
  tournament. Refusing here instead would mean a legacy tournament - one
  published before keys existed, holding the player names and email addresses
  this whole feature is about - could never be taken down at all, which is the
  hole rather than the fix.
  """
  @spec authorize_delete(String.t(), String.t() | nil) :: outcome()
  def authorize_delete(slug, presented), do: authorize(slug, presented, :delete)

  @doc """
  May this request READ `slug`'s registration queue?

  The only route that returns an email address, so it is the one read worth
  gating twice. Before this existed, any holder of the server-wide ingest
  token could pull the entries for a tournament it had never published -
  which is exactly the authority a per-tournament key exists to divide.

  Same rule as deletion, and unclaimed behaves the same way for the same
  reason: a tournament published before keys existed must stay reachable by
  the arbiter running it, and that arbiter has nothing to present. Refusing
  would strand the queue rather than protect it.
  """
  @spec authorize_read(String.t(), String.t() | nil) :: outcome()
  def authorize_read(slug, presented), do: authorize(slug, presented, :read)

  @doc """
  Has `slug` been claimed?

  Diagnostic. It says nothing about whether the tournament has published.
  """
  @spec claimed?(String.t()) :: boolean()
  def claimed?(slug), do: not is_nil(fetch(slug))

  @doc """
  Forgets the claim on `slug`, returning how many rows went.

  Part of a takedown and only that. There is no other way to release a key,
  because the point of a claim is that it outlives the machine's mood.
  """
  @spec release(String.t()) :: non_neg_integer()
  def release(slug) do
    {count, _returned} =
      from(k in TournamentKey, where: k.tournament_slug == ^slug) |> Repo.delete_all()

    count
  end

  @doc """
  The digest stored for a key: SHA-256, lowercase hex.

  Public so a test can assert the plaintext key is nowhere in the row. Nothing
  on the request path should need it.
  """
  @spec hash(String.t()) :: String.t()
  def hash(key) when is_binary(key) do
    :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)
  end

  @doc """
  Normalises a presented key: `nil` for anything that is not a usable secret.

  An empty or whitespace-only header is treated as ABSENT rather than as a
  key, and that is not politeness. `hash("")` is a publicly known constant, so
  claiming a slug with a blank key would hand it to anyone who could send an
  empty header - a claimed slug that anybody can re-claim is worse than an
  unclaimed one, because it looks protected.
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(key) when is_binary(key) do
    case String.trim(key) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize(_absent_or_not_a_string), do: nil

  defp authorize(slug, presented, action) do
    case {fetch(slug), normalize(presented)} do
      # Unclaimed and nothing presented: a legacy slug, or a client too old to
      # know about keys. Publishes as it always did, and stays unclaimed.
      {nil, nil} ->
        :ok

      {nil, key} ->
        unclaimed(slug, key, action)

      # Claimed, and the request did not even try. Refused: this is the case
      # that stops a claimed tournament being taken over by omission.
      {%TournamentKey{}, nil} ->
        {:error, :key_required}

      {%TournamentKey{} = claim, key} ->
        compare(slug, claim, key, action)
    end
  end

  defp unclaimed(slug, key, action) do
    cond do
      # Checked BEFORE claiming, never after. See the moduledoc: the
      # server-wide token must never end up stored as a tournament key.
      break_glass?(key) ->
        warn_break_glass(slug, action, "slug is not claimed, so nothing was claimed for it")
        :ok

      # Neither deleting nor reading may CLAIM. Delete would leave a key row
      # pointing at nothing; read would let a pull silently take ownership of
      # a tournament this machine has never published, which is the opposite
      # of what a read should do.
      action in [:delete, :read] ->
        :ok

      true ->
        claim(slug, key)
    end
  end

  defp claim(slug, key) do
    %TournamentKey{}
    |> TournamentKey.changeset(%{
      tournament_slug: slug,
      key_hash: hash(key),
      claimed_at: DateTime.utc_now()
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: :tournament_slug)

    # Re-read rather than trust what the insert reported. `on_conflict:
    # :nothing` succeeds whether it wrote or was beaten to it, and on SQLite it
    # returns a struct either way - so the insert's own answer cannot tell
    # "I claimed this" from "somebody else did, a microsecond ago".
    #
    # Reading back and judging against whatever row now exists collapses both
    # into one rule: first publish wins, and a second machine racing it with a
    # DIFFERENT key is refused exactly as it would be a day later.
    case fetch(slug) do
      # Only reachable if the row was deleted between the insert and this
      # read - a takedown landing mid-publish. Nothing is claimed and the
      # publish stands, which is the same outcome as an unclaimed slug.
      nil -> :ok
      claim -> compare(slug, claim, key, :publish)
    end
  end

  defp compare(slug, %TournamentKey{key_hash: stored}, key, action) do
    cond do
      # The real key first, so an ordinary publish never trips the break-glass
      # log even in the pathological case where the two secrets are equal.
      Plug.Crypto.secure_compare(stored, hash(key)) ->
        :ok

      break_glass?(key) ->
        warn_break_glass(slug, action, "the tournament key was overridden")
        :ok

      true ->
        {:error, :key_mismatch}
    end
  end

  defp break_glass?(key) do
    case Application.get_env(:openresults, :ingest_token) do
      token when is_binary(token) and token != "" ->
        # Digests for the same reason `IngestAuth` uses them: `secure_compare/2`
        # returns early on a length difference and would otherwise leak how long
        # the server token is.
        Plug.Crypto.secure_compare(hash(token), hash(key))

      _unset ->
        false
    end
  end

  defp fetch(slug), do: Repo.get_by(TournamentKey, tournament_slug: slug)

  # Loud on purpose, and at warning rather than info: this is the audit trail
  # for somebody using the master key on a single tournament, and the question
  # it has to answer afterwards is "when did that happen and to what". The key
  # itself is never in the line - the whole point is that secrets do not get
  # written down.
  defp warn_break_glass(slug, action, detail) do
    Logger.warning(
      "BREAK-GLASS: #{action} on #{inspect(slug)} authorised with the server-wide " <>
        "ingest token instead of the tournament key - #{detail}"
    )
  end
end
