defmodule OpenResultsWeb.EventGroup do
  @moduledoc """
  One event made of several tournaments - the Open, the U20, the U12 - as
  the pages show it: a tab strip at the top of each tournament's pages, an
  event page that lists them, and one entry on the front page.

  It starts from `tournament.group` in a snapshot (`docs/snapshot-schema.md`)
  and ends with what `OpenResults.TournamentGroups` lets through. A sibling
  is shown only when it is public on this server, its OWN snapshot names the
  same event, and it has the same publisher - see that module for why a
  snapshot's word about another tournament is never enough. A snapshot
  without the block, and one whose siblings all fail those checks, renders
  exactly as a tournament in no event: no strip, no gap, nothing.

  One more rule, kept here as well as in the arbiter's app: a tournament that
  is not listed on the front page is never linked from one that is. A listed
  page is reachable by anyone browsing; naming a link-only section there
  would list it by another door.
  """

  use OpenResultsWeb, :verified_routes

  alias OpenResults.TournamentGroups
  alias OpenResults.Tournaments
  alias OpenResultsWeb.Tournament

  @max_siblings 40
  @max_text 160

  @doc """
  The snapshot's `group` block, checked and trimmed, or nil:
  `%{id, name, label, position, siblings: [%{slug, label, name}]}`.

  Display text is cut to a length a page can hold; a sibling without a slug
  is dropped; anything that is not the shape the contract describes makes
  the whole block absent rather than half-read.
  """
  @spec block(map()) :: map() | nil
  def block(payload) do
    with id when is_binary(id) <- TournamentGroups.claimed_id(payload),
         %{"name" => name} = group when is_binary(name) and name != "" <-
           Tournament.info(payload)["group"] do
      siblings =
        for %{"slug" => slug} = sibling when is_binary(slug) and slug != "" <-
              List.wrap(group["siblings"]) |> Enum.take(@max_siblings) do
          name = text(sibling["name"]) || text(sibling["label"]) || slug
          %{slug: slug, name: name, label: text(sibling["label"]) || name}
        end

      %{
        id: id,
        name: text(name),
        label: text(group["label"]) || Tournament.name(payload),
        position: position(group["position"]),
        siblings: siblings
      }
    else
      _absent_or_malformed -> nil
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_text)
    end
  end

  defp text(_other), do: nil

  defp position(n) when is_integer(n) and n >= 1 and n <= @max_siblings + 1, do: n
  defp position(_other), do: 1

  @doc """
  The tab strip for one page of `slug`, or nil when there is nothing to
  switch to: `%{id, name, tabs: [%{label, name, href, current?}]}`.

  `current` is the page being rendered (the masthead's `current`): a
  sibling's tab opens the same page there when it has one - standings to
  standings, round 3 to round 3, the cross-table to the cross-table - and
  its overview otherwise.
  """
  @spec strip(map(), String.t(), term()) :: map() | nil
  def strip(payload, slug, current) do
    with %{siblings: [_ | _]} = block <- block(payload),
         confirmed when confirmed != [] <- confirmed_siblings(block, payload, slug) do
      own = %{label: block.label, name: Tournament.name(payload), href: nil, current?: true}

      tabs =
        for {sibling, sibling_payload} <- confirmed do
          %{
            label: sibling.label,
            name: sibling.name,
            href: same_page(sibling.slug, sibling_payload, current),
            current?: false
          }
        end

      # The place the arbiter gave this tournament, counted among the
      # siblings that are actually shown.
      before = Enum.count(confirmed, fn {sibling, _} -> sibling.index < block.position - 1 end)

      %{id: block.id, name: block.name, tabs: List.insert_at(tabs, before, own)}
    else
      _no_block_or_nobody_to_show -> nil
    end
  end

  # The siblings of `block` this server vouches for, in the block's order,
  # each with the place it has in the full list (self included) and its own
  # current payload.
  defp confirmed_siblings(block, payload, slug) do
    siblings = Enum.reject(block.siblings, &(&1.slug == slug))
    facts = TournamentGroups.facts([slug | Enum.map(siblings, & &1.slug)])
    listed? = Tournament.listed?(payload)

    case Map.get(facts, slug) do
      %{event_id: id} = own when id == block.id ->
        siblings
        |> Enum.with_index()
        |> Enum.flat_map(fn {sibling, i} ->
          # The index in the list WITH self in it: self sits at position - 1.
          index = if i >= block.position - 1, do: i + 1, else: i

          with %{event_id: ^id, installation_id: installation, status: status}
               when installation == own.installation_id and status != "hidden" <-
                 Map.get(facts, sibling.slug),
               %{payload: sibling_payload} <- Tournaments.public_latest(sibling.slug),
               true <- Tournament.listed?(sibling_payload) or not listed? do
            [{Map.put(sibling, :index, index), sibling_payload}]
          else
            _not_vouched_for -> []
          end
        end)

      _no_row_or_another_event ->
        []
    end
  end

  # The same page of a sibling, when it has that page; its overview when not.
  defp same_page(slug, payload, {:round, n}) when is_integer(n) do
    if Tournament.show?(payload, "pairings") and Tournament.round(payload, n),
      do: ~p"/t/#{slug}/round/#{n}",
      else: ~p"/t/#{slug}"
  end

  defp same_page(slug, payload, :crosstable) do
    if Tournament.crosstable?(payload), do: ~p"/t/#{slug}/crosstable", else: ~p"/t/#{slug}"
  end

  defp same_page(slug, payload, :teams) do
    if Tournament.show?(payload, "standings") and Tournament.team_event?(payload) and
         Tournament.teams(payload) != [],
       do: ~p"/t/#{slug}/teams",
       else: ~p"/t/#{slug}"
  end

  defp same_page(slug, payload, :board_prizes) do
    if Tournament.show?(payload, "standings") and Tournament.team_event?(payload) and
         Tournament.board_stats(payload) != [],
       do: ~p"/t/#{slug}/board-prizes",
       else: ~p"/t/#{slug}"
  end

  defp same_page(slug, _payload, _standings_or_a_page_of_one_tournament), do: ~p"/t/#{slug}"

  @doc """
  The tournaments of event `id`, for its page: `{name, members}` with
  `members` as `%{slug, label, payload}` in the event's order, or nil when
  fewer than two can be shown - an event of one is a tournament.

  When any member is listed on the front page the unlisted ones are left
  out: this page is linked from the listed ones.
  """
  @spec members(String.t()) :: {String.t(), [map()]} | nil
  def members(id) when is_binary(id) do
    members =
      for slug <- TournamentGroups.member_slugs(id),
          %{payload: payload} <- [Tournaments.public_latest(slug)],
          %{id: ^id} = block <- [block(payload)] do
        %{
          slug: slug,
          label: block.label,
          position: block.position,
          name: block.name,
          payload: payload
        }
      end

    members =
      if Enum.any?(members, &Tournament.listed?(&1.payload)),
        do: Enum.filter(members, &Tournament.listed?(&1.payload)),
        else: members

    case Enum.sort_by(members, &{&1.position, Tournament.name(&1.payload)}) do
      [first, _second | _] = sorted -> {first.name, sorted}
      _none_or_one -> nil
    end
  end

  def members(_not_an_id), do: nil

  @doc """
  Which of `snapshots` the front page shows as part of an event:
  `%{slug => %{id, name, label, position}}`.

  Only what `snapshots` holds counts - the caller has already left out the
  hidden and the unlisted - and only tournaments of the event's own
  publisher. An event with one tournament in the list is that tournament,
  and is absent here.
  """
  @spec memberships([struct()]) :: %{String.t() => map()}
  def memberships(snapshots) do
    blocks =
      for snapshot <- snapshots, block = block(snapshot.payload), into: %{} do
        {snapshot.tournament_slug, block}
      end

    if blocks == %{}, do: %{}, else: confirmed_memberships(blocks)
  end

  defp confirmed_memberships(blocks) do
    facts = TournamentGroups.facts(Map.keys(blocks))
    owners = TournamentGroups.owners(blocks |> Map.values() |> Enum.map(& &1.id) |> Enum.uniq())

    held =
      for {slug, block} <- blocks,
          %{event_id: id, installation_id: installation} <- [Map.get(facts, slug)],
          id == block.id and Map.fetch(owners, id) == {:ok, installation},
          into: %{} do
        {slug, Map.take(block, [:id, :name, :label, :position])}
      end

    sizes = held |> Map.values() |> Enum.frequencies_by(& &1.id)
    Map.filter(held, fn {_slug, member} -> Map.fetch!(sizes, member.id) > 1 end)
  end

  @doc """
  One section of the front page with its events gathered: each entry is
  `{:tournament, snapshot}` or `{:event, %{id, name}, [{label, snapshot}]}`,
  an event standing where its first tournament stood, its tournaments in the
  event's own order. `memberships` is `memberships/1` of the whole page, so
  an event whose sections are in different parts of the page - the rapid
  finished, the Open still running - is named in each.
  """
  @spec gather([struct()], %{String.t() => map()}) :: [tuple()]
  def gather(snapshots, memberships) do
    by_event =
      snapshots
      |> Enum.filter(&Map.has_key?(memberships, &1.tournament_slug))
      |> Enum.group_by(&Map.fetch!(memberships, &1.tournament_slug).id)

    {entries, _seen} =
      Enum.flat_map_reduce(snapshots, MapSet.new(), fn snapshot, seen ->
        case Map.get(memberships, snapshot.tournament_slug) do
          nil ->
            {[{:tournament, snapshot}], seen}

          %{id: id} = member ->
            if MapSet.member?(seen, id) do
              {[], seen}
            else
              members =
                by_event
                |> Map.fetch!(id)
                |> Enum.map(&{Map.fetch!(memberships, &1.tournament_slug), &1})
                |> Enum.sort_by(fn {m, s} -> {m.position, Tournament.name(s.payload)} end)
                |> Enum.map(fn {m, s} -> {m.label, s} end)

              {[{:event, %{id: id, name: member.name}, members}], MapSet.put(seen, id)}
            end
        end
      end)

    entries
  end
end
