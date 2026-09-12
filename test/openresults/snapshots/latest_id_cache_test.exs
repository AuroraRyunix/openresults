defmodule OpenResults.Snapshots.LatestIdCacheTest do
  # Not async: one ETS table, named and shared, exactly like
  # `OpenResults.RateLimitTest` for the same reason.
  use ExUnit.Case

  alias OpenResults.Snapshots.LatestIdCache

  setup do
    LatestIdCache.clear()
    :ok
  end

  describe "fetch/1" do
    test "is a miss for a slug nothing has cached" do
      assert LatestIdCache.fetch("nope") == :miss
    end

    test "is a hit for whatever was last put" do
      LatestIdCache.put("gent-spring-open-2026", 41)

      assert LatestIdCache.fetch("gent-spring-open-2026") == {:ok, 41}
    end

    test "one slug's entry does not answer for another" do
      LatestIdCache.put("gent-spring-open-2026", 41)

      assert LatestIdCache.fetch("antwerp-winter-open-2026") == :miss
    end
  end

  describe "put/2" do
    test "a later put wins, so a publish is always visible at once" do
      LatestIdCache.put("gent-spring-open-2026", 41)
      LatestIdCache.put("gent-spring-open-2026", 42)

      assert LatestIdCache.fetch("gent-spring-open-2026") == {:ok, 42}
    end
  end

  describe "forget/1" do
    test "a forgotten slug is a miss again, not the id it used to hold" do
      LatestIdCache.put("gent-spring-open-2026", 41)
      LatestIdCache.forget("gent-spring-open-2026")

      assert LatestIdCache.fetch("gent-spring-open-2026") == :miss
    end

    test "forgetting a slug nothing cached is a no-op, not an error" do
      assert LatestIdCache.forget("nope") == :ok
    end
  end

  describe "clear/0" do
    test "forgets every slug, not only one" do
      LatestIdCache.put("gent-spring-open-2026", 41)
      LatestIdCache.put("antwerp-winter-open-2026", 7)

      LatestIdCache.clear()

      assert LatestIdCache.fetch("gent-spring-open-2026") == :miss
      assert LatestIdCache.fetch("antwerp-winter-open-2026") == :miss
    end
  end
end
