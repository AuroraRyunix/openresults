defmodule OpenResults.ModerationTransferAllTest do
  @moduledoc """
  `Moderation.transfer_all/3`: every tournament of one installation moved to
  another in one step - the restore case, where a laptop restored from backup
  comes back as a new installation because no backup carries the installation
  key.

  Each tournament has to move exactly as `transfer/3` moves one, and the whole
  move has to be all or nothing: half an installation's tournaments on the new
  laptop and half stranded on the old key is worse than either.
  """

  # Not async, like ModerationTest: status changes write node-wide caches.
  use OpenResults.DataCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments

  @actor %{email: "moderator@example.invalid"}

  defp published_by(installation) do
    slug = mint!(installation)
    {:ok, _} = Snapshots.ingest(payload(slug), installation: installation, key: random_key())
    slug
  end

  # The old laptop: one tournament in each status, and one minted but never
  # published.
  defp old_laptop do
    {old, _key} = installation!()
    pending = published_by(old)
    listed = published_by(old)
    {:ok, _} = Moderation.approve(listed, @actor)
    hidden = published_by(old)
    {:ok, _} = Moderation.hide(hidden, @actor)
    unpublished = mint!(old)

    {old, %{pending: pending, listed: listed, hidden: hidden, unpublished: unpublished}}
  end

  defp actions, do: Moderation.list_actions(%{limit: 1000})

  describe "moving everything" do
    test "every tournament, in every status, each exactly as transfer/3 would move it" do
      {old, slugs} = old_laptop()
      {new, _key} = installation!()
      {bystander, _key} = installation!()
      untouched = published_by(bystander)
      before = length(actions())

      assert {:ok, %{from: from, to: to, slugs: moved}} =
               Moderation.transfer_all(old.id, new.id, @actor)

      assert {from, to} == {old.id, new.id}
      assert Enum.sort(moved) == Enum.sort(Map.values(slugs))

      for {status, slug} <- slugs do
        tournament = Tournaments.get(slug)

        # Rebound, status unchanged, key released.
        assert tournament.installation_id == new.id
        assert tournament.status == Atom.to_string(status_of(status))
        refute TournamentKeys.claimed?(slug)
      end

      # Nobody else's tournament moves.
      assert Tournaments.get(untouched).installation_id == bystander.id
      assert TournamentKeys.claimed?(untouched)

      # One transfer row per tournament, exactly transfer/3's, and one for
      # the whole move.
      new_rows = Enum.take(actions(), length(actions()) - before)
      assert length(new_rows) == map_size(slugs) + 1

      [whole | per_tournament] = new_rows

      assert %Action{
               actor: "moderator@example.invalid",
               action: "transfer_all",
               target_type: "installation",
               target: ^from,
               details: %{"to" => ^to, "slugs" => logged}
             } = whole

      assert Enum.sort(logged) == Enum.sort(moved)

      for row <- per_tournament do
        assert %Action{
                 action: "transfer",
                 target_type: "tournament",
                 details: %{"from" => ^from, "to" => ^to}
               } = row

        assert row.target in moved
      end
    end

    test "the new laptop's next keyed publish claims a moved tournament; the old key is refused" do
      {old, %{pending: slug}} = old_laptop()
      {new, _key} = installation!()

      {:ok, _} = Moderation.transfer_all(old.id, new.id, @actor)

      assert {:error, :not_owner} =
               Snapshots.ingest(SnapshotPayloads.republished(payload(slug)),
                 installation: old,
                 key: random_key()
               )

      key = random_key()

      assert {:ok, _} =
               Snapshots.ingest(SnapshotPayloads.republished(payload(slug)),
                 installation: new,
                 key: key
               )

      assert TournamentKeys.claimed?(slug)
    end

    test "moves from a revoked or suspended installation - the old laptop's key may already be" do
      for status <- [:revoked, :suspended] do
        {old, %{pending: slug}} = old_laptop()
        {new, _key} = installation!()

        case status do
          :revoked -> {:ok, _} = Moderation.revoke(old.id, @actor, hide_tournaments: false)
          :suspended -> {:ok, _} = Moderation.suspend(old.id, @actor)
        end

        assert {:ok, _} = Moderation.transfer_all(old.id, new.id, @actor)
        assert Tournaments.get(slug).installation_id == new.id
      end
    end
  end

  describe "refusals, with nothing moved and nothing logged" do
    setup do
      {old, slugs} = old_laptop()
      {:ok, old: old, slugs: slugs, before: length(actions())}
    end

    defp assert_nothing_moved(old, slugs, before) do
      for slug <- Map.values(slugs) do
        assert Tournaments.get(slug).installation_id == old.id
      end

      assert length(actions()) == before
    end

    test "to itself", %{old: old, slugs: slugs, before: before} do
      assert Moderation.transfer_all(old.id, old.id, @actor) == {:error, :same_installation}
      assert_nothing_moved(old, slugs, before)
    end

    test "to an installation that does not exist, or from one", %{
      old: old,
      slugs: slugs,
      before: before
    } do
      assert Moderation.transfer_all(old.id, "in_nobody", @actor) == {:error, :not_found}
      {other, _key} = installation!()
      assert Moderation.transfer_all("in_nobody", other.id, @actor) == {:error, :not_found}
      assert_nothing_moved(old, slugs, before)
    end

    test "to a revoked installation", %{old: old, slugs: slugs} do
      {revoked, _key} = installation!()
      {:ok, _} = Moderation.revoke(revoked.id, @actor, hide_tournaments: false)
      before = length(actions())

      assert Moderation.transfer_all(old.id, revoked.id, @actor) ==
               {:error, :installation_revoked}

      assert_nothing_moved(old, slugs, before)
    end

    test "to a suspended installation, whose key could publish none of them", %{
      old: old,
      slugs: slugs
    } do
      {suspended, _key} = installation!()
      {:ok, _} = Moderation.suspend(suspended.id, @actor)
      before = length(actions())

      assert Moderation.transfer_all(old.id, suspended.id, @actor) ==
               {:error, :installation_suspended}

      assert_nothing_moved(old, slugs, before)
    end

    test "from an installation that owns nothing" do
      {empty, _key} = installation!()
      {other, _key} = installation!()
      before = length(actions())

      assert Moderation.transfer_all(empty.id, other.id, @actor) == {:error, :no_tournaments}
      assert length(actions()) == before
    end

    test "an actor that is not %{email: _} raises", %{old: old} do
      {other, _key} = installation!()
      assert_raise ArgumentError, fn -> Moderation.transfer_all(old.id, other.id, nil) end
    end
  end

  describe "all or nothing" do
    test "a failure on the last tournament rolls back every move, key and log row" do
      {old, slugs} = old_laptop()
      {new, _key} = installation!()
      before = length(actions())

      # The order the move walks them in. Mints in the same clock tick tie on
      # `inserted_at`, so this is read rather than assumed.
      order =
        Repo.all(
          from t in OpenResults.Tournaments.Tournament,
            where: t.installation_id == ^old.id,
            order_by: [asc: t.inserted_at, asc: t.slug],
            select: t.slug
        )

      assert Enum.sort(order) == Enum.sort(Map.values(slugs))
      {earlier, [last]} = Enum.split(order, -1)

      # The tournament moved last refuses the update, the way a disk error or
      # a constraint would. Created inside this test's sandboxed transaction,
      # and dropped again below.
      Repo.query!("""
      CREATE TRIGGER refuse_last_move BEFORE UPDATE OF installation_id ON tournaments
      WHEN OLD.slug = '#{last}'
      BEGIN SELECT RAISE(ABORT, 'refused for the test'); END;
      """)

      assert_raise Exqlite.Error, ~r/refused for the test/, fn ->
        Moderation.transfer_all(old.id, new.id, @actor)
      end

      Repo.query!("DROP TRIGGER refuse_last_move")

      # The three moved before it are back where they were, keys included.
      for slug <- order do
        assert Tournaments.get(slug).installation_id == old.id, slug
      end

      for slug <- earlier, slug != slugs.unpublished do
        assert TournamentKeys.claimed?(slug), slug
      end

      assert length(actions()) == before

      # And once nothing is refusing, the same move goes through whole, in the
      # order read above - so the refused one really did come after three
      # moves that were then undone.
      assert {:ok, %{slugs: moved}} = Moderation.transfer_all(old.id, new.id, @actor)
      assert moved == order
    end
  end

  defp status_of(:pending), do: :pending
  defp status_of(:listed), do: :listed
  defp status_of(:hidden), do: :hidden
  defp status_of(:unpublished), do: :pending
end
