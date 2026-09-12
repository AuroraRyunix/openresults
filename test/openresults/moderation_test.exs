defmodule OpenResults.ModerationTest do
  @moduledoc """
  `OpenResults.Moderation` at the context level - the admin panel only renders
  what these return, so this is where its behaviour is pinned down.
  """

  # Not async: status changes write the node-wide StatusCache and page cache.
  use OpenResults.DataCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.AddressBlocks.Block
  alias OpenResults.Installations.Installation
  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.Reports
  alias OpenResults.Reports.Report
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments
  alias OpenResults.Tournaments.Tournament
  alias OpenResultsWeb.Plugs.Revalidate.Page

  @actor %{email: "moderator@example.invalid"}

  # Every public name and arity the contract lists. If one is renamed, the
  # panel breaks - so this fails first.
  @contract [
    settings: 0,
    put_setting: 3,
    list_tournaments: 1,
    get_tournament: 1,
    approve: 2,
    hide: 2,
    unhide: 2,
    delete: 2,
    transfer: 3,
    list_installations: 1,
    get_installation: 1,
    suspend: 2,
    unsuspend: 2,
    revoke: 3,
    list_reports: 1,
    resolve_report: 3,
    block_address: 4,
    list_blocks: 0,
    unblock: 2,
    installations_seen_from: 1,
    list_actions: 1
  ]

  test "exports exactly the functions docs/public-publishing.md names" do
    Code.ensure_loaded!(Moderation)

    for {name, arity} <- @contract do
      assert function_exported?(Moderation, name, arity), "missing Moderation.#{name}/#{arity}"
    end
  end

  defp published_by_installation do
    {installation, _key} = installation!()
    slug = mint!(installation)
    {:ok, _} = Snapshots.ingest(payload(slug), installation: installation, key: random_key())
    {installation, slug}
  end

  defp actions, do: Moderation.list_actions(%{})

  defp last_action, do: hd(actions())

  describe "switches" do
    test "default to closed and not paused, and put_setting logs who flipped what" do
      assert Moderation.settings() == %{registration_open: false, public_publishing_paused: false}

      assert {:ok, %{registration_open: true, public_publishing_paused: false}} =
               Moderation.put_setting(:registration_open, true, @actor)

      assert {:ok, %{registration_open: true, public_publishing_paused: true}} =
               Moderation.put_setting(:public_publishing_paused, true, @actor)

      assert {:ok, %{registration_open: false}} =
               Moderation.put_setting(:registration_open, false, @actor)

      assert [
               %Action{
                 action: "put_setting",
                 target: "registration_open",
                 details: %{"value" => false}
               },
               %Action{target: "public_publishing_paused", details: %{"value" => true}},
               %Action{actor: "moderator@example.invalid", target_type: "setting"}
             ] = actions()
    end

    test "refuses unknown keys and non-booleans, and writes nothing" do
      assert Moderation.put_setting(:open_the_floodgates, true, @actor) ==
               {:error, :unknown_setting}

      assert Moderation.put_setting(:registration_open, "yes", @actor) == {:error, :invalid_value}
      assert actions() == []
    end

    test "an actor that is not %{email: _} raises" do
      assert_raise ArgumentError, fn -> Moderation.put_setting(:registration_open, true, nil) end
      assert_raise ArgumentError, fn -> Moderation.approve("x", %{name: "me"}) end
    end
  end

  describe "tournament status" do
    test "approve: pending to listed, logged, and refused from any other status" do
      {_installation, slug} = published_by_installation()

      assert {:ok, %Tournament{status: "listed"}} = Moderation.approve(slug, @actor)
      assert Tournaments.status(slug) == :listed
      assert %Action{action: "approve", target_type: "tournament", target: ^slug} = last_action()

      assert Moderation.approve(slug, @actor) == {:error, :invalid_status}
      assert Moderation.approve("never-minted", @actor) == {:error, :not_found}
      assert length(actions()) == 1
    end

    test "hide from pending or listed, unhide to listed" do
      {_installation, pending} = published_by_installation()
      listed = unique_slug()
      {:ok, _} = Snapshots.ingest(payload(listed))

      for slug <- [pending, listed] do
        assert {:ok, %Tournament{status: "hidden"}} = Moderation.hide(slug, @actor)
        assert Tournaments.status(slug) == :hidden
        assert Tournaments.public_latest(slug) == nil
        assert Moderation.hide(slug, @actor) == {:error, :invalid_status}

        assert {:ok, %Tournament{status: "listed"}} = Moderation.unhide(slug, @actor)
        assert Tournaments.status(slug) == :listed
        assert Moderation.unhide(slug, @actor) == {:error, :invalid_status}
      end

      assert actions() |> Enum.map(& &1.action) |> Enum.frequencies() == %{
               "hide" => 2,
               "unhide" => 2
             }
    end

    test "a status change drops that tournament's cached pages in every language, and no other's" do
      {_installation, slug} = published_by_installation()
      neighbour = unique_slug()
      {:ok, neighbour_snapshot} = Snapshots.ingest(payload(neighbour))

      id = Snapshots.latest_id(slug)

      for locale <- ~w(en nl fr) do
        Page.put(slug, id, locale, "tag-#{locale}", "page")
      end

      Page.put(neighbour, neighbour_snapshot.id, "en", "tag", "neighbour page")

      {:ok, _} = Moderation.approve(slug, @actor)

      for locale <- ~w(en nl fr), do: assert(Page.get(slug, id, locale, "tag-#{locale}") == nil)
      assert Page.get(neighbour, neighbour_snapshot.id, "en", "tag") == "neighbour page"
    end
  end

  describe "listing tournaments" do
    setup do
      {installation, pending} = published_by_installation()
      unpublished = mint!(installation)

      listed = unique_slug("findme")

      {:ok, _} =
        Snapshots.ingest(put_in(payload(listed), ["tournament", "name"], "Brugge Rapid 50%"))

      {:ok, _} = Reports.create(pending, %{"reason" => "spam_or_offensive"}, {198, 51, 100, 1})
      {:ok, resolved} = Reports.create(listed, %{"reason" => "other"}, nil)
      {:ok, _} = Reports.resolve(resolved.id, "fine", "someone")

      {:ok,
       installation: installation, pending: pending, unpublished: unpublished, listed: listed}
    end

    test "carries name, last publish and open report count", %{
      pending: pending,
      unpublished: unpublished,
      listed: listed
    } do
      by_slug = Map.new(Moderation.list_tournaments(%{}), &{&1.slug, &1})

      assert %{name: "Gent Spring Open 2026", open_reports: 1, last_published_at: %DateTime{}} =
               by_slug[pending]

      assert %{name: nil, open_reports: 0, last_published_at: nil, status: "pending"} =
               by_slug[unpublished]

      assert %{name: "Brugge Rapid 50%", open_reports: 0, status: "listed"} = by_slug[listed]
    end

    test "filters by status, installation, reported? and search", %{
      installation: installation,
      pending: pending,
      unpublished: unpublished,
      listed: listed
    } do
      slugs = fn filters ->
        filters |> Moderation.list_tournaments() |> Enum.map(& &1.slug) |> Enum.sort()
      end

      assert slugs.(status: :pending) == Enum.sort([pending, unpublished])
      assert slugs.(%{"status" => "listed"}) == [listed]
      assert slugs.(installation_id: installation.id) == Enum.sort([pending, unpublished])
      assert slugs.(reported?: true) == [pending]
      assert slugs.(search: "findme") == [listed]
      assert slugs.(search: "rapid 50%") == [listed]
      # `%` is text, not a wildcard.
      assert slugs.(search: "%") == [listed]
      assert slugs.(search: "nothing like this") == []
      assert length(Moderation.list_tournaments(limit: 1)) == 1
    end

    test "get_tournament has the same fields and the installation preloaded", %{
      installation: installation,
      pending: pending
    } do
      assert %Tournament{slug: ^pending, open_reports: 1, installation: %Installation{id: id}} =
               Moderation.get_tournament(pending)

      assert id == installation.id
      assert Moderation.get_tournament("nope") == nil
    end
  end

  describe "delete/2" do
    test "purges everything, logs the counts, and is idempotent" do
      {_installation, slug} = published_by_installation()

      assert {:ok, %{snapshots: 1, registrations: 0, key: 1}} = Moderation.delete(slug, @actor)
      assert Snapshots.history(slug) == []
      assert Tournaments.get(slug) == nil
      refute TournamentKeys.claimed?(slug)

      assert %Action{action: "delete", target: ^slug, details: %{"snapshots" => 1, "key" => 1}} =
               last_action()

      assert {:ok, %{snapshots: 0}} = Moderation.delete(slug, @actor)
    end
  end

  describe "transfer/3" do
    test "rebinds ownership and clears the stored key, so the target's next keyed publish claims it" do
      {from, slug} = published_by_installation()
      {to, _to_key} = installation!()

      assert TournamentKeys.claimed?(slug)

      assert {:ok, %Tournament{installation_id: to_id, status: "pending"}} =
               Moderation.transfer(slug, to.id, @actor)

      assert to_id == to.id
      refute TournamentKeys.claimed?(slug)

      assert %Action{action: "transfer", details: %{"from" => from_id, "to" => ^to_id}} =
               last_action()

      assert from_id == from.id

      # The dead laptop's installation can no longer publish...
      new_key = random_key()

      assert {:error, :not_owner} =
               Snapshots.ingest(SnapshotPayloads.republished(payload(slug)),
                 installation: from,
                 key: random_key()
               )

      # ...and the new one claims the slug with its own key on its first publish.
      assert {:ok, _} =
               Snapshots.ingest(SnapshotPayloads.republished(payload(slug)),
                 installation: to,
                 key: new_key
               )

      assert TournamentKeys.claimed?(slug)

      assert {:error, :key_mismatch} =
               Snapshots.ingest(payload(slug), installation: to, key: random_key())
    end

    test "can adopt an operator-published tournament for an installation" do
      slug = unique_slug()
      {:ok, _} = Snapshots.ingest(payload(slug), key: random_key())
      {to, _} = installation!()

      assert {:ok, %Tournament{installation_id: id, status: "listed"}} =
               Moderation.transfer(slug, to.id, @actor)

      assert id == to.id
    end

    test "refuses an unknown tournament, an unknown installation and a revoked one" do
      {_from, slug} = published_by_installation()
      {revoked, _} = installation!()
      {:ok, _} = Moderation.revoke(revoked.id, @actor, hide_tournaments: false)
      count = length(actions())

      assert Moderation.transfer(slug, "in_nobody", @actor) == {:error, :not_found}
      assert Moderation.transfer(slug, revoked.id, @actor) == {:error, :installation_revoked}

      assert Moderation.transfer("no-such-slug", revoked.id, @actor) ==
               {:error, :installation_revoked}

      {other, _} = installation!()
      assert Moderation.transfer("no-such-slug", other.id, @actor) == {:error, :not_found}
      assert length(actions()) == count
    end
  end

  describe "installations" do
    test "suspend and unsuspend, logged, with transitions refused otherwise" do
      {installation, _key} = installation!()

      assert {:ok, %Installation{status: "suspended"}} =
               Moderation.suspend(installation.id, @actor)

      assert Moderation.suspend(installation.id, @actor) == {:error, :invalid_status}

      assert {:ok, %Installation{status: "active"}} =
               Moderation.unsuspend(installation.id, @actor)

      assert Moderation.unsuspend(installation.id, @actor) == {:error, :invalid_status}
      assert Moderation.suspend("in_nobody", @actor) == {:error, :not_found}

      id = installation.id

      assert [
               %Action{action: "unsuspend", target_type: "installation", target: ^id},
               %Action{action: "suspend", target: ^id}
             ] = actions()
    end

    test "revoke without hiding leaves its tournaments as they are" do
      {installation, slug} = published_by_installation()

      assert {:ok, %Installation{status: "revoked"}} =
               Moderation.revoke(installation.id, @actor, hide_tournaments: false)

      assert Tournaments.status(slug) == :pending

      assert %Action{action: "revoke", details: %{"hide_tournaments" => false, "hidden" => []}} =
               last_action()

      # Revoked is final.
      assert Moderation.revoke(installation.id, @actor, hide_tournaments: true) ==
               {:error, :invalid_status}

      assert Moderation.unsuspend(installation.id, @actor) == {:error, :invalid_status}
    end

    test "revoke with hide_tournaments hides its pending and listed tournaments, and only its own" do
      {installation, pending} = published_by_installation()
      listed = mint!(installation)
      {:ok, _} = Moderation.approve(listed, @actor)
      {_other, others} = published_by_installation()

      assert {:ok, _} = Moderation.revoke(installation.id, @actor, hide_tournaments: true)

      assert Tournaments.status(pending) == :hidden
      assert Tournaments.status(listed) == :hidden
      assert Tournaments.status(others) == :pending

      assert %Action{details: %{"hide_tournaments" => true, "hidden" => hidden}} = last_action()
      assert Enum.sort(hidden) == Enum.sort([pending, listed])
    end

    test "list_installations counts pending and listed tournaments, and filters" do
      {one, _} = installation!({192, 0, 2, 1})
      _ = mint!(one)
      hidden = mint!(one)
      {:ok, _} = Moderation.hide(hidden, @actor)
      {two, _} = installation!({192, 0, 2, 2})
      {:ok, _} = Moderation.suspend(two.id, @actor)

      counts = Map.new(Moderation.list_installations(%{}), &{&1.id, &1.tournament_count})
      assert counts[one.id] == 1
      assert counts[two.id] == 0

      assert [%Installation{id: id}] = Moderation.list_installations(status: "suspended")
      assert id == two.id
      assert [%Installation{id: ^id}] = Moderation.list_installations(search: "192.0.2.2")

      assert %Installation{tournaments: tournaments} = Moderation.get_installation(one.id)
      assert length(tournaments) == 2
      assert Moderation.get_installation("in_nobody") == nil
    end
  end

  describe "reports" do
    test "list by status and resolve with a logged resolution" do
      slug = unique_slug()

      {:ok, open} =
        Reports.create(slug, %{"reason" => "wrong_or_fake_results", "details" => "no"}, nil)

      {:ok, other} = Reports.create(slug, %{"reason" => "other"}, nil)

      assert Enum.map(Moderation.list_reports(:open), & &1.id) |> Enum.sort() ==
               Enum.sort([open.id, other.id])

      assert {:ok,
              %Report{status: "resolved", resolution: "hidden the tournament", resolved_by: by}} =
               Moderation.resolve_report(open.id, "hidden the tournament", @actor)

      assert by == @actor.email

      assert [%Report{id: id}] = Moderation.list_reports(:resolved)
      assert id == open.id
      assert [%Report{id: other_id}] = Moderation.list_reports(%{"status" => "open"})
      assert other_id == other.id

      assert Moderation.resolve_report(open.id, "again", @actor) == {:error, :already_resolved}
      assert Moderation.resolve_report(999_999, "x", @actor) == {:error, :not_found}

      assert [
               %Action{
                 action: "resolve_report",
                 target_type: "report",
                 details: %{"slug" => ^slug}
               }
             ] =
               actions()
    end
  end

  describe "address blocks" do
    test "block, list and unblock a range, all logged" do
      expires = DateTime.add(DateTime.utc_now(), 7 * 86_400)

      assert {:ok, %Block{cidr: "203.0.113.0/24", reason: "flood"} = block} =
               Moderation.block_address("203.0.113.77/24", expires, " flood ", @actor)

      assert [%Block{id: id}] = Moderation.list_blocks()
      assert id == block.id

      assert {:ok, _} = Moderation.unblock(block.id, @actor)
      assert Moderation.list_blocks() == []
      assert Moderation.unblock(block.id, @actor) == {:error, :not_found}

      assert [
               %Action{action: "unblock"},
               %Action{action: "block_address", details: %{"cidr" => "203.0.113.0/24"}}
             ] =
               actions()
    end

    test "every block expires, within 30 days, and has a reason" do
      now = DateTime.utc_now()

      for {cidr, expires, reason} <- [
            {"203.0.113.1", nil, "x"},
            {"203.0.113.1", DateTime.add(now, -1), "x"},
            {"203.0.113.1", DateTime.add(now, 31 * 86_400), "x"},
            {"203.0.113.1", DateTime.add(now, 3600), ""},
            {"not an address", DateTime.add(now, 3600), "x"},
            {"203.0.113.1/33", DateTime.add(now, 3600), "x"}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Moderation.block_address(cidr, expires, reason, @actor)
      end

      assert Moderation.list_blocks() == []
      assert actions() == []
    end

    test "installations_seen_from counts registration and last-seen addresses in the range" do
      {_a, _} = installation!({203, 0, 113, 5})
      {b, _} = installation!({198, 51, 100, 5})
      OpenResults.Installations.touch(b, {203, 0, 113, 200})
      {_c, _} = installation!({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7109})
      {_d, _} = installation!({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})

      assert Moderation.installations_seen_from("203.0.113.0/24") == 3
      assert Moderation.installations_seen_from("203.0.113.5") == 1
      assert Moderation.installations_seen_from("2001:db8::/32") == 1
      assert Moderation.installations_seen_from("0.0.0.0/0") == 3
      assert Moderation.installations_seen_from("rubbish") == 0
    end
  end

  describe "the action log" do
    test "filters by actor, action and target, newest first, limited" do
      {installation, slug} = published_by_installation()
      {:ok, _} = Moderation.approve(slug, @actor)
      {:ok, _} = Moderation.suspend(installation.id, %{email: "other@example.invalid"})

      assert [%Action{action: "suspend"}, %Action{action: "approve"}] = actions()
      assert [%Action{action: "approve"}] = Moderation.list_actions(actor: @actor.email)
      assert [%Action{action: "suspend"}] = Moderation.list_actions(%{"action" => "suspend"})

      assert [%Action{target: ^slug}] =
               Moderation.list_actions(target_type: "tournament", target: slug)

      assert [_one] = Moderation.list_actions(limit: 1)
    end

    test "break-glass is written with the actor break-glass" do
      slug = unique_slug()
      {:ok, _} = Snapshots.ingest(payload(slug), key: random_key())

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = TournamentKeys.authorize_delete(slug, operator_token())
      end)

      assert [%Action{actor: "break-glass", action: "break_glass_delete", target: ^slug}] =
               actions()
    end
  end
end
