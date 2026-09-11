defmodule OpenResultsWeb.PageCacheTest do
  @moduledoc """
  A publish costs one render and then N sends, rather than N renders.

  Safe only because these pages are byte-identical for every reader who
  asks for them the same way: no login, no session, no CSRF token in the
  layout. The tests that matter are the ones proving a page can never be
  served to somebody it was not rendered for - a stale one, which is the
  property CDN caching was rejected to protect, or one in the wrong
  language, which is what translating the site put at risk.
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.Plugs.Revalidate.Page

  setup do
    Snapshots.clear_cache()
    Page.clear()

    on_exit(fn ->
      Snapshots.clear_cache()
      Page.clear()
    end)

    swiss = SnapshotPayloads.swiss()
    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  test "the second reader gets the same bytes as the first", %{conn: conn, slug: slug} do
    first = conn |> get(~p"/t/#{slug}") |> html_response(200)
    second = build_conn() |> get(~p"/t/#{slug}") |> html_response(200)

    assert first == second
  end

  test "a publish makes the stored page unreachable, not merely old", %{
    conn: conn,
    slug: slug,
    swiss: swiss
  } do
    # The property CDN caching was rejected to protect. A new version must
    # never be shadowed by a rendered page from the previous one.
    before = conn |> get(~p"/t/#{slug}") |> html_response(200)
    assert before =~ "after round 2"

    changed = put_in(swiss, ["standings", "after_round"], 4)
    {:ok, _} = Snapshots.ingest(changed)

    now = build_conn() |> get(~p"/t/#{slug}") |> html_response(200)

    assert now =~ "after round 4"
    refute now == before
  end

  test "each page is stored separately, and one never stands in for another", %{
    conn: conn,
    slug: slug
  } do
    standings = conn |> get(~p"/t/#{slug}") |> html_response(200)
    player = build_conn() |> get(~p"/t/#{slug}/player/1") |> html_response(200)

    refute standings == player

    # And each is still itself on a second read.
    assert build_conn() |> get(~p"/t/#{slug}") |> html_response(200) == standings
    assert build_conn() |> get(~p"/t/#{slug}/player/1") |> html_response(200) == player
  end

  test "one reader's language is never served to a reader who asked for another", %{slug: slug} do
    # The precondition this whole cache rests on used to be "every reader
    # gets byte-identical HTML". Translating the pages made that false, and
    # nothing about the store would have noticed: the Dutch body would sit
    # under a key the French request matched, and the French reader would be
    # handed Dutch - silently, and only when they happened to be second.
    dutch =
      build_conn()
      |> put_req_header("accept-language", "nl-BE,nl;q=0.9")
      |> get(~p"/t/#{slug}")
      |> html_response(200)

    assert dutch =~ "De uitslagen zijn van hen"

    french =
      build_conn()
      |> put_req_header("accept-language", "fr-BE,fr;q=0.9")
      |> get(~p"/t/#{slug}")
      |> html_response(200)

    assert french =~ "Les résultats sont les siens"
    refute french =~ "De uitslagen zijn van hen"

    # And the Dutch reader who comes back still gets Dutch rather than the
    # French page that was stored after theirs.
    again =
      build_conn()
      |> put_req_header("accept-language", "nl-BE,nl;q=0.9")
      |> get(~p"/t/#{slug}")
      |> html_response(200)

    assert again == dutch
  end

  test "the projector view and the ordinary round page are stored separately", %{
    conn: conn,
    slug: slug
  } do
    # Same path, different query string. A shared cache entry here would mean
    # whichever one rendered first - the projector or the ordinary page - got
    # served back for both, to every subsequent reader of either URL.
    round = conn |> get(~p"/t/#{slug}/round/1") |> html_response(200)
    display = build_conn() |> get(~p"/t/#{slug}/round/1?display=1") |> html_response(200)

    refute round == display
    # A substring check on the raw HTML would also match the layout's own
    # script, which mentions the `[data-projector]` selector by name on every
    # page - the element itself is the real signal.
    assert display
           |> LazyHTML.from_document()
           |> LazyHTML.query("[data-projector]")
           |> Enum.any?()

    refute round |> LazyHTML.from_document() |> LazyHTML.query("[data-projector]") |> Enum.any?()

    assert build_conn() |> get(~p"/t/#{slug}/round/1") |> html_response(200) == round
    assert build_conn() |> get(~p"/t/#{slug}/round/1?display=1") |> html_response(200) == display
  end

  test "a 404 is never stored as though it were the document", %{conn: conn} do
    assert conn |> get(~p"/t/nope") |> html_response(404)
    assert build_conn() |> get(~p"/t/nope") |> html_response(404)
  end

  test "a withheld page is not stored either", %{conn: conn, swiss: swiss} do
    # `player_cards` off means the player route answers 404. Storing that
    # against the tournament's version would be storing a refusal.
    hidden =
      swiss
      |> put_in(["tournament", "slug"], "no-cards")
      |> put_in(["tournament", "display", "player_cards"], false)

    {:ok, _} = Snapshots.ingest(hidden)

    assert conn |> get(~p"/t/no-cards/player/1") |> html_response(404)
    assert build_conn() |> get(~p"/t/no-cards") |> html_response(200)
  end

  test "clearing the cache costs a re-render, not correctness", %{conn: conn, slug: slug} do
    first = conn |> get(~p"/t/#{slug}") |> html_response(200)
    Page.clear()

    assert build_conn() |> get(~p"/t/#{slug}") |> html_response(200) == first
  end

  describe "the store itself" do
    test "answers nil for a version it does not hold" do
      assert Page.get("nobody", 999, "en", ~s("999-1")) == nil
    end

    test "a get before the table exists returns nil rather than raising" do
      # The table is created lazily. Deleting it (not merely clearing it, as
      # `Page.clear/0` does) is the only way to put the store back into that
      # pre-existence state from a test.
      if :ets.whereis(:openresults_page_cache) != :undefined,
        do: :ets.delete(:openresults_page_cache)

      assert Page.get("nobody", 999, "en", ~s("999-1")) == nil
    end

    test "a new snapshot for the same tournament drops that tournament's old entries" do
      Page.put("alpha", 1, "en", ~s("1-a"), "old")
      assert Page.get("alpha", 1, "en", ~s("1-a")) == "old"

      Page.put("alpha", 2, "en", ~s("2-a"), "new")

      refute Page.get("alpha", 1, "en", ~s("1-a"))
      assert Page.get("alpha", 2, "en", ~s("2-a")) == "new"
    end

    test "one page in two languages is two entries, not one" do
      # The locale is in the key, and this is the unit-level statement of
      # why. Without it the second language to be rendered would either
      # overwrite the first or - worse - be served the first's body, because
      # everything else about the two requests is identical: same tournament,
      # same snapshot, same path.
      #
      # There is an end-to-end test for this in revalidate_test.exs, over the
      # ETag. This one is about the store, which is the other half: the ETag
      # stops a BROWSER being told nothing changed, the key stops the SERVER
      # handing over the wrong body in the first place.
      Page.put("alpha", 1, "nl", ~s("1-nl"), "de stand")
      Page.put("alpha", 1, "fr", ~s("1-fr"), "le classement")

      assert Page.get("alpha", 1, "nl", ~s("1-nl")) == "de stand"
      assert Page.get("alpha", 1, "fr", ~s("1-fr")) == "le classement"
    end

    test "and a language this tournament has never served is a miss, not a guess" do
      # The failure that would look like success: falling back to whatever
      # body is stored for the same slug and snapshot. A miss costs a
      # re-render; a fallback serves Dutch to somebody who asked in French.
      Page.put("alpha", 1, "nl", ~s("1-nl"), "de stand")

      refute Page.get("alpha", 1, "fr", ~s("1-nl"))
      refute Page.get("alpha", 1, "en", ~s("1-nl"))
    end

    test "a publish clears the tournament's pages in every language" do
      # The other direction, and the one that would rot quietly: if eviction
      # were keyed by locale as well, a new snapshot would drop the Dutch
      # copy and leave the French one, so a French reader would keep being
      # served last publish's standings. Scoping is per TOURNAMENT; the
      # locale belongs in the key, not in the sweep.
      Page.put("alpha", 1, "nl", ~s("1-nl"), "oude stand")
      Page.put("alpha", 1, "fr", ~s("1-fr"), "ancien classement")

      Page.put("alpha", 2, "nl", ~s("2-nl"), "nieuwe stand")

      refute Page.get("alpha", 1, "nl", ~s("1-nl"))
      refute Page.get("alpha", 1, "fr", ~s("1-fr"))
      assert Page.get("alpha", 2, "nl", ~s("2-nl")) == "nieuwe stand"
    end

    test "one tournament's publish does not evict another tournament's pages" do
      # This is the defect this store used to have: one global version row
      # meant ANY tournament publishing discarded the whole table, so every
      # other live tournament's cache was wiped too. Snapshot ids are
      # distinct per tournament here on purpose - they come from one shared,
      # globally auto-incrementing table in real use, so this is what two
      # tournaments publishing independently actually looks like.
      Page.put("alpha", 1, "en", ~s("1-a"), "alpha's page")
      Page.put("bravo", 2, "en", ~s("2-a"), "bravo's page")

      # Bravo publishes again - a new snapshot id, but only for bravo.
      Page.put("bravo", 3, "en", ~s("3-a"), "bravo's new page")

      assert Page.get("alpha", 1, "en", ~s("1-a")) == "alpha's page"
      assert Page.get("bravo", 3, "en", ~s("3-a")) == "bravo's new page"
      refute Page.get("bravo", 2, "en", ~s("2-a"))
    end

    test "the per-tournament cap drops only that tournament's entries" do
      # Bravo's one page sits untouched on either side of alpha walking
      # itself past its own cap (512) - the flood is alpha's problem alone.
      Page.put("bravo", 1, "en", ~s("1-a"), "bravo's page")
      for n <- 1..514, do: Page.put("alpha", 1, "en", ~s("1-#{n}"), "alpha page #{n}")

      refute Page.get("alpha", 1, "en", ~s("1-1"))
      assert Page.get("alpha", 1, "en", ~s("1-514")) == "alpha page 514"
      assert Page.get("bravo", 1, "en", ~s("1-a")) == "bravo's page"
    end

    test "clear/0 empties everything, every tournament included" do
      Page.put("alpha", 1, "en", ~s("1-a"), "alpha's page")
      Page.put("bravo", 1, "en", ~s("1-a"), "bravo's page")

      Page.clear()

      refute Page.get("alpha", 1, "en", ~s("1-a"))
      refute Page.get("bravo", 1, "en", ~s("1-a"))
    end
  end
end
