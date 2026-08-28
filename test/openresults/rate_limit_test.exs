defmodule OpenResults.RateLimitTest do
  # Not async, and not `DataCase`: this touches no database and one ETS table
  # that every test in the run shares.
  use ExUnit.Case

  alias OpenResults.RateLimit

  @window :timer.minutes(10)

  setup do
    RateLimit.reset()
    :ok
  end

  defp take(key, now), do: RateLimit.take(key, limit: 3, window_ms: @window, now: now)

  describe "take/2" do
    test "allows the limit and refuses what comes after it" do
      now = 1_700_000_000_000

      assert take(:someone, now) == :ok
      assert take(:someone, now) == :ok
      assert take(:someone, now) == :ok
      assert {:denied, _left} = take(:someone, now)
    end

    test "says how long is left, so the page can say it too" do
      # Two minutes into a ten minute window.
      now = 3 * @window + :timer.minutes(2)

      for _ <- 1..3, do: take(:someone, now)

      assert {:denied, left} = take(:someone, now)
      assert left == :timer.minutes(8)
    end

    test "a new window starts from nothing" do
      now = 5 * @window

      for _ <- 1..3, do: take(:someone, now)
      assert {:denied, _left} = take(:someone, now)

      assert take(:someone, now + @window) == :ok
    end

    test "one client's flood is not another client's problem" do
      now = 1_700_000_000_000

      for _ <- 1..4, do: take({:registration, {203, 0, 113, 7}}, now)

      assert {:denied, _left} = take({:registration, {203, 0, 113, 7}}, now)
      assert take({:registration, {198, 51, 100, 2}}, now) == :ok
    end
  end

  describe "the sweep" do
    test "reclaims windows that have ended and leaves the current one alone" do
      # An unauthenticated endpoint means anybody can create a key, so a table
      # that only ever grew would be a slow way of running this server out of
      # memory from the outside.
      now = System.system_time(:millisecond)

      take(:long_gone, now - 3 * @window)
      take(:here_now, now)

      assert :ets.info(RateLimit, :size) == 2

      send(RateLimit, :sweep)
      # Waits for the sweep to have been handled rather than sleeping for it.
      _state = :sys.get_state(RateLimit)

      # And the surviving row still remembers its count, rather than merely
      # existing: one take has already happened, so a limit of one is spent.
      assert :ets.info(RateLimit, :size) == 1
      assert {:denied, _left} = RateLimit.take(:here_now, limit: 1, window_ms: @window, now: now)
    end
  end
end
