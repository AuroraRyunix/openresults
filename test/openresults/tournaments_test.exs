defmodule OpenResults.TournamentsTest do
  # Not async: StatusCache is node-wide.
  use OpenResults.DataCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Installations
  alias OpenResults.Moderation
  alias OpenResults.Snapshots
  alias OpenResults.Takedown
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments
  alias OpenResults.Tournaments.StatusCache
  alias OpenResults.Tournaments.Tournament

  describe "mint/2" do
    test "a 12-character base64url slug, pending, bound, unpublished" do
      {installation, _} = installation!()

      assert {:ok,
              %Tournament{
                slug: slug,
                status: "pending",
                installation_id: id,
                minted_at: %DateTime{}
              }} =
               Tournaments.mint(installation)

      assert id == installation.id
      assert slug =~ ~r/\A[A-Za-z0-9_-]{12}\z/
      assert Tournaments.status(slug) == :pending
      assert Snapshots.latest(slug) == nil
    end

    test "never the same slug twice" do
      {installation, _} = installation!()
      slugs = for _ <- 1..50, do: mint!(installation)
      assert length(Enum.uniq(slugs)) == 50
    end

    test "the limit counts pending and listed, not hidden" do
      {installation, _} = installation!()

      [a, b] =
        for _ <- 1..2,
            do: Tournaments.mint(installation, limit: 2) |> elem(1) |> Map.fetch!(:slug)

      assert Tournaments.mint(installation, limit: 2) == {:error, {:tournament_limit, 2}}
      {:ok, _} = Moderation.approve(a, admin())
      assert Tournaments.mint(installation, limit: 2) == {:error, {:tournament_limit, 2}}
      {:ok, _} = Moderation.hide(b, admin())
      assert {:ok, _} = Tournaments.mint(installation, limit: 2)
    end
  end

  describe "status/1" do
    test "a slug with no row is listed; operator publishes write a listed row" do
      slug = unique_slug()
      assert Tournaments.status(slug) == :listed
      assert Tournaments.get(slug) == nil

      {:ok, _} = Snapshots.ingest(payload(slug))

      assert %Tournament{status: "listed", installation_id: nil, minted_at: nil} =
               Tournaments.get(slug)
    end

    test "an operator publish to an installation's tournament neither adopts nor approves it" do
      {installation, _} = installation!()
      slug = mint!(installation)

      {:ok, _} = Snapshots.ingest(payload(slug))

      assert %Tournament{status: "pending", installation_id: id} = Tournaments.get(slug)
      assert id == installation.id
    end

    test "a reader's late answer never overwrites a writer's" do
      slug = unique_slug()
      {:ok, _} = Snapshots.ingest(payload(slug))

      # A writer committed `hidden`...
      StatusCache.put(slug, :hidden)
      # ...and a reader that queried before that commit arrives afterwards.
      StatusCache.remember(slug, :listed)

      assert Tournaments.status(slug) == :hidden
    end

    test "a takedown leaves the slug reading as no row, not as its old status" do
      {installation, _} = installation!()
      slug = mint!(installation)
      {:ok, _} = Snapshots.ingest(payload(slug), installation: installation, key: random_key())
      {:ok, _} = Moderation.hide(slug, admin())
      assert Tournaments.status(slug) == :hidden

      Takedown.purge(slug)

      assert Tournaments.get(slug) == nil
      assert Tournaments.status(slug) == :listed
      assert Tournaments.public_latest(slug) == nil
    end
  end

  describe "Snapshots.list_current(listed_only: true)" do
    test "leaves pending and hidden tournaments out in the query; without the option nothing is left out" do
      {installation, _} = installation!()
      pending = mint!(installation)
      {:ok, _} = Snapshots.ingest(payload(pending), installation: installation, key: random_key())
      hidden = mint!(installation)
      {:ok, _} = Snapshots.ingest(payload(hidden), installation: installation, key: random_key())
      {:ok, _} = Moderation.hide(hidden, admin())
      listed = unique_slug()
      {:ok, _} = Snapshots.ingest(payload(listed))

      assert Enum.map(Snapshots.list_current(listed_only: true), & &1.tournament_slug) == [listed]

      assert Enum.sort(Enum.map(Snapshots.list_current(), & &1.tournament_slug)) ==
               Enum.sort([pending, hidden, listed])
    end
  end

  describe "publishing with an installation" do
    test "only to its own slug, and never to a hidden one" do
      {mine, _} = installation!()
      {theirs, _} = installation!()
      slug = mint!(mine)

      assert {:error, :not_owner} =
               Snapshots.ingest(payload(slug), installation: theirs, key: random_key())

      assert {:error, :not_owner} =
               Snapshots.ingest(payload(unique_slug()), installation: mine, key: random_key())

      key = random_key()
      assert {:ok, _} = Snapshots.ingest(payload(slug), installation: mine, key: key)
      {:ok, _} = Moderation.hide(slug, admin())

      assert {:error, :tournament_hidden} =
               Snapshots.ingest(OpenResults.SnapshotPayloads.republished(payload(slug)),
                 installation: mine,
                 key: key
               )
    end

    test "a refused publish writes nothing - not the claim, not a row" do
      {mine, _} = installation!()
      stranger = unique_slug()

      assert {:error, :not_owner} =
               Snapshots.ingest(payload(stranger), installation: mine, key: random_key())

      refute TournamentKeys.claimed?(stranger)
      assert Tournaments.get(stranger) == nil
      assert Snapshots.history(stranger) == []
    end
  end

  describe "release_unpublished_before/1" do
    test "releases only minted slugs older than the cutoff that never published" do
      {installation, _} = installation!()
      old = ~U[2026-07-01 00:00:00.000000Z]
      cutoff = ~U[2026-08-13 00:00:00.000000Z]

      {:ok, %{slug: stale}} = Tournaments.mint(installation, now: old)
      {:ok, %{slug: published}} = Tournaments.mint(installation, now: old)

      {:ok, _} =
        Snapshots.ingest(payload(published), installation: installation, key: random_key())

      {:ok, %{slug: fresh}} = Tournaments.mint(installation, now: ~U[2026-09-01 00:00:00.000000Z])

      operator = unique_slug()
      {:ok, _} = Snapshots.ingest(payload(operator))

      assert Tournaments.release_unpublished_before(cutoff) == [stale]
      assert Tournaments.get(stale) == nil
      assert Tournaments.get(published)
      assert Tournaments.get(fresh)
      assert Tournaments.get(operator)

      # Released means the installation no longer owns it.
      assert {:error, :not_owner} =
               Snapshots.ingest(payload(stale), installation: installation, key: random_key())

      refute is_nil(Installations.get(installation.id))
    end
  end
end
