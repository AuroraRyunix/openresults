defmodule OpenResults.StatsTest do
  @moduledoc """
  The stats page's counters: what one increment records, how finished minutes
  become the hour and the day, the slug cap, the histogram's percentiles and
  the `/proc` readers.

  Each test uses a table and a collector of its own, and drives time by
  passing it, so nothing here sleeps and nothing touches the node's own
  counters.
  """
  use ExUnit.Case, async: true

  alias OpenResults.Stats
  alias OpenResults.Stats.Collector
  alias OpenResults.Stats.Histogram
  alias OpenResults.Stats.Report
  alias OpenResults.Stats.SystemInfo

  @proc Path.expand("../fixtures/proc", __DIR__)

  # A minute on a quarter-hour boundary, far from the real clock.
  @m0 1_000_005 * 15
  @t0 @m0 * 60

  defp start_collector(opts \\ []) do
    table = :"stats_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Collector,
         Keyword.merge(
           [
             name: nil,
             table: table,
             clock: fn -> @t0 end,
             tick: :manual,
             db_interval: :manual,
             proc_root: @proc
           ],
           opts
         )},
        id: table
      )

    {pid, table}
  end

  # A row as the page will read it: `{minute, tag}`'s rows from every
  # scheduler added together, key first; `[]` when there is none.
  defp row(table, {minute, tag}) do
    rows = for row <- :ets.tab2list(table), match?({^minute, ^tag, _}, elem(row, 0)), do: row

    case rows do
      [] ->
        []

      [first | _] ->
        values =
          rows
          |> Enum.map(&(&1 |> Tuple.to_list() |> tl()))
          |> Enum.zip_with(&Enum.sum/1)

        [elem(first, 0) | values]
    end
  end

  # For a message another process sends: asks again until it holds, a few
  # hundred times at most.
  defp eventually(check, tries \\ 400) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        receive do
        after
          5 -> eventually(check, tries - 1)
        end
    end
  end

  defp point(points, minute) do
    {^minute, bucket} = List.keyfind(points, minute, 0)
    bucket
  end

  describe "a request increment" do
    test "counts its route group and status class, and its duration bucket, in one row" do
      {_pid, table} = start_collector()

      Stats.record_request(table, @m0, :public, 200, 400)
      Stats.record_request(table, @m0, :public, 200, 400)
      Stats.record_request(table, @m0, :public, 304, 150)
      Stats.record_request(table, @m0, :public, 404, 3_000)
      Stats.record_request(table, @m0, :static, 301, 90)
      Stats.record_request(table, @m0, :api_write, 503, 1_000)
      Stats.record_request(table, @m0, :admin, nil, 7_000_000)

      [_key, c2xx, c304, c3xx, c4xx, c5xx | buckets] = row(table, {@m0, :public})

      assert {c2xx, c304, c3xx, c4xx, c5xx} == {2, 1, 0, 1, 0}
      # 400 us -> the 0.5 ms bucket, 150 us -> 0.2 ms, 3 ms -> 5 ms.
      assert Enum.at(buckets, Histogram.index(400)) == 2
      assert Enum.at(buckets, Histogram.index(150)) == 1
      assert Enum.at(buckets, Histogram.index(3_000)) == 1
      assert Enum.sum(buckets) == 4

      assert [_, 0, 0, 1, 0, 0 | _] = row(table, {@m0, :static})
      assert [_, 0, 0, 0, 0, 1 | _] = row(table, {@m0, :api_write})
      # No status at all is counted as a server error; past 5 s is overflow.
      assert [_, 0, 0, 0, 0, 1 | admin_buckets] = row(table, {@m0, :admin})
      assert Enum.at(admin_buckets, Histogram.size() - 1) == 1
    end

    test "creates its row when the collector has not, and never raises without a table" do
      {_pid, table} = start_collector()
      later = @m0 + 500

      assert row(table, {later, :api_read}) == []
      assert Stats.record_request(table, later, :api_read, 200, 10) == :ok
      assert [_, 1, 0, 0, 0, 0 | _] = row(table, {later, :api_read})

      assert Stats.record_request(:no_such_table, @m0, :public, 200, 10) == :ok
      assert Stats.count(:no_such_table, @m0, :mint) == :ok
      assert Stats.record_view(:no_such_table, @m0, "x") == :ok
      assert Stats.record_query(:no_such_table, @m0, 1, 1) == :ok
    end

    test "the page cache's decision rides in the request's own increment" do
      {_pid, table} = start_collector()

      Stats.record_request(table, @m0, :public, 200, 400, :hit)
      Stats.record_request(table, @m0, :public, 200, 400, :miss)
      Stats.record_request(table, @m0, :public, 304, 400, :not_modified)

      [_key, c2xx, c304 | rest] = row(table, {@m0, :public})
      assert {c2xx, c304} == {2, 1}
      assert Enum.take(rest, -3) == [1, 1, 1]
      assert Enum.at(rest, 3 + Histogram.index(400)) == 3
    end

    test "page cache, events and queries each count where the page reads them" do
      {pid, table} = start_collector()

      for outcome <- [:hit, :hit, :hit, :miss, :not_modified],
          do: Stats.record_request(table, @m0, :public, 200, 400, outcome)

      Stats.count(table, @m0, {:publish, :operator})
      Stats.count(table, @m0, {:refused, :storage_low})
      Stats.count(table, @m0, {:refused, :storage_low})
      Stats.record_query(table, @m0, 300, 1_500)
      Stats.record_query(table, @m0, 300, nil)

      bucket = Collector.report(pid, @t0 + 10).hour |> point(@m0)

      assert Report.cache(bucket) == %{
               hits: 3,
               misses: 1,
               not_modified: 1,
               hit_rate: 75.0,
               revalidation_share: 20.0
             }

      assert Report.event(bucket, {:publish, :operator}) == 1
      assert Report.refusals(bucket) == [{:storage_low, 2}]

      repo = Report.repo(bucket)
      assert repo.queries == 2
      assert repo.queued == 1
      assert repo.query.p95 == 500
      assert repo.queue.p95 == 2_000
    end
  end

  describe "minutes" do
    test "a minute is folded out of the table once it has ended, and not before" do
      {pid, table} = start_collector()

      for _ <- 1..3, do: Stats.record_request(table, @m0, :public, 200, 400)

      :ok = Collector.tick(pid, @t0 + 30)
      # Still the current minute: the rows stay, and the report reads them live.
      assert [_, 3, 0, 0, 0, 0 | _] = row(table, {@m0, :public})
      report = Collector.report(pid, @t0 + 30)
      assert Report.requests(report.hour |> List.last() |> elem(1), :public) == 3

      :ok = Collector.tick(pid, @t0 + 60)
      assert row(table, {@m0, :public}) == []
      # ... and the next minute's rows are already waiting.
      assert [_, 0, 0, 0, 0, 0 | _] = row(table, {@m0 + 1, :public})
      assert [_, 0, 0, 0, 0, 0 | _] = row(table, {@m0 + 2, :public})

      report = Collector.report(pid, @t0 + 60)
      assert length(report.hour) == 61
      assert Report.requests(point(report.hour, @m0), :public) == 3
      assert Report.requests(report.hour |> List.last() |> elem(1), :all) == 0
    end

    test "an increment that lands after its minute was folded is added to that minute" do
      {pid, table} = start_collector()

      Stats.record_request(table, @m0, :public, 200, 400)
      :ok = Collector.tick(pid, @t0 + 61)
      Stats.record_request(table, @m0, :public, 500, 400)
      :ok = Collector.tick(pid, @t0 + 66)

      bucket = Collector.report(pid, @t0 + 66).hour |> point(@m0)

      assert Report.status_classes(bucket) == [
               {"2xx", 1},
               {"304", 0},
               {"3xx", 0},
               {"4xx", 0},
               {"5xx", 1}
             ]
    end

    test "the hour keeps 60 finished minutes; the day keeps quarter hours for 24 hours" do
      {pid, table} = start_collector()

      # Two requests in each of 90 minutes, ticking as the clock would.
      for i <- 0..89 do
        Stats.record_request(table, @m0 + i, :public, 200, 400)
        Stats.record_request(table, @m0 + i, :api_read, 200, 400)
        :ok = Collector.tick(pid, @t0 + (i + 1) * 60 + 1)
      end

      now = @t0 + 90 * 60 + 1
      report = Collector.report(pid, now)

      # Minutes 30..89 finished within the hour, plus the empty current one.
      assert length(report.hour) == 61
      assert Report.requests(Report.total(report.hour), :all) == 120
      assert Report.requests(Report.total(report.hour), :public) == 60
      refute List.keymember?(report.hour, @m0 + 29, 0)

      # The day still has all 90 minutes, in quarter hours of 30 requests.
      assert length(report.day) == 96
      assert Report.requests(Report.total(report.day), :all) == 180
      assert Report.requests(point(report.day, @m0), :all) == 30
      assert Report.requests(point(report.day, @m0 + 75), :all) == 30
      assert {_q, last} = List.last(report.day)
      assert Report.requests(last, :all) == 0

      assert [_ | _] = hourly = Report.hourly(report.day)
      assert length(hourly) == 24
      assert Report.requests(Report.total(hourly), :all) == 180

      # A day later the quarter hours have aged out too.
      a_day_later = now + 24 * 3600
      :ok = Collector.tick(pid, a_day_later)
      report = Collector.report(pid, a_day_later)
      assert Report.requests(Report.total(report.day), :all) == 0
      assert map_size(:sys.get_state(pid).quarters) <= 96
      assert map_size(:sys.get_state(pid).minutes) <= 61
    end

    test "each minute keeps the CPU and load it was sampled with" do
      {pid, _table} = start_collector()

      :ok = Collector.tick(pid, @t0 + 5)
      :ok = Collector.tick(pid, @t0 + 10)

      report = Collector.report(pid, @t0 + 10)
      bucket = List.last(report.hour) |> elem(1)

      assert Report.gauge(bucket, :load) == 0.52
      # The fixture does not move between two readings: no CPU time passed.
      assert Report.gauge(bucket, :cpu) == nil
      assert report.system.load == {0.52, 0.38, 0.21}

      assert report.system.memory == %{
               total_bytes: 4_028_000 * 1024,
               available_bytes: 2_014_000 * 1024
             }

      assert report.system.beam.schedulers_online == System.schedulers_online()
    end
  end

  describe "busiest tournaments" do
    test "past the cap, a new slug's requests go to other, and the table stops growing" do
      {pid, table} = start_collector()
      cap = Stats.slug_cap()

      for i <- 1..(cap + 5), do: Stats.record_view(table, @m0, "slug-#{i}")
      # A slug already admitted keeps counting.
      for _ <- 1..3, do: Stats.record_view(table, @m0, "slug-1")
      # One past the cap is still refused a row on its second request.
      Stats.record_view(table, @m0, "slug-#{cap + 1}")

      slug_rows = :ets.select_count(table, [{{{@m0, {:slug, :_}, :_}, :_}, [], [true]}])
      assert slug_rows == cap
      assert [{_, 6}] = :ets.lookup(table, {@m0, :slug_other, 0})

      bucket = Collector.report(pid, @t0 + 10).hour |> List.last() |> elem(1)
      assert {[{"slug-1", 4} | _], rest} = Report.top_slugs(bucket, 10)
      # Every counted request is either in the top ten or in the rest.
      assert rest == cap + 5 + 3 + 1 - 4 - 9
    end

    test "a finished minute keeps its 200 busiest slugs and folds the others" do
      bucket = %{Collector.empty() | slugs: Map.new(1..250, &{"s#{&1}", &1})}
      trimmed = Collector.trim_slugs(bucket, 200)

      assert map_size(trimmed.slugs) == 200
      assert trimmed.slugs["s250"] == 250
      refute Map.has_key?(trimmed.slugs, "s50")
      assert trimmed.slug_other == Enum.sum(1..50)
    end

    test "refreshes are counted, capped and trimmed apart from views" do
      {pid, table} = start_collector()

      Stats.record_view(table, @m0, "s1")
      Stats.record_view(table, @m0, "s1")
      Stats.record_refresh(table, @m0, "s1")
      Stats.record_refresh(table, @m0, "s1")
      Stats.record_refresh(table, @m0, "s1")
      Stats.record_refresh(table, @m0, "s2")

      bucket = Collector.report(pid, @t0 + 10).hour |> List.last() |> elem(1)
      assert Report.top_slugs(bucket, 10) == {[{"s1", 2}], 0}
      assert Report.top_refreshes(bucket, 10) == {[{"s1", 3}, {"s2", 1}], 0}
      assert Report.refresh_total(bucket) == 4

      trimmed =
        %{Collector.empty() | refreshes: Map.new(1..250, &{"r#{&1}", &1})}
        |> Collector.trim_slugs(200)

      assert map_size(trimmed.refreshes) == 200
      assert trimmed.refreshes["r250"] == 250
      refute Map.has_key?(trimmed.refreshes, "r50")
      assert trimmed.refresh_other == Enum.sum(1..50)
      # Trimming refreshes never touches the (empty, here) views side.
      assert trimmed.slugs == %{}
      assert trimmed.slug_other == 0
    end

    test "past the cap, a slug's refreshes go to their own other row, apart from views" do
      {_pid, table} = start_collector()
      cap = Stats.slug_cap()

      for i <- 1..(cap + 5), do: Stats.record_refresh(table, @m0, "r-#{i}")

      refresh_rows = :ets.select_count(table, [{{{@m0, {:refresh, :_}, :_}, :_}, [], [true]}])
      assert refresh_rows == cap
      assert [{_, 5}] = :ets.lookup(table, {@m0, :refresh_other, 0})
      # A view of the same slug in the same minute is counted, unaffected by
      # the refresh cap having already been hit.
      Stats.record_view(table, @m0, "r-1")
      assert [_key, 1] = row(table, {@m0, {:slug, "r-1"}})
    end
  end

  describe "live followers" do
    test "is nil with no finished minutes to estimate from" do
      assert Report.live_followers([]) == nil
    end

    test "is refreshes over the points divided by 3 per minute" do
      minute = %{Collector.empty() | refreshes: %{"a" => 6}}
      other = %{Collector.empty() | refreshes: %{"a" => 3}, refresh_other: 3}

      # 6 + (3 + 3) = 12 refreshes over 2 minutes: 6 a minute, "about 3 taps
      # a minute per open page" makes that 2 open pages.
      assert Report.live_followers([{1, minute}, {2, other}]) == 2.0
    end
  end

  describe "the histogram" do
    test "bucket edges" do
      assert Histogram.index(0) == 0
      assert Histogram.index(100) == 0
      assert Histogram.index(101) == 1
      assert Histogram.index(1_000) == 3
      assert Histogram.index(5_000_000) == 14
      assert Histogram.index(5_000_001) == Histogram.size() - 1
    end

    test "percentiles on known inputs" do
      # 100 samples: 50 at <= 0.1 ms, 45 at <= 1 ms, 4 at <= 10 ms, 1 past 5 s.
      counts =
        Histogram.empty()
        |> List.replace_at(0, 50)
        |> List.replace_at(3, 45)
        |> List.replace_at(6, 4)
        |> List.replace_at(Histogram.size() - 1, 1)

      assert Histogram.percentile(counts, 50) == 100
      assert Histogram.percentile(counts, 51) == 1_000
      assert Histogram.percentile(counts, 95) == 1_000
      assert Histogram.percentile(counts, 96) == 10_000
      assert Histogram.percentile(counts, 99) == 10_000
      assert Histogram.percentile(counts, 100) == :overflow
      assert Histogram.percentile(Histogram.empty(), 50) == nil

      single = List.replace_at(Histogram.empty(), 5, 1)
      assert Histogram.percentile(single, 1) == 5_000
      assert Histogram.percentile(single, 99) == 5_000
    end
  end

  describe "/proc" do
    test "reads the fixture files" do
      assert SystemInfo.loadavg(@proc) == {:ok, {0.52, 0.38, 0.21}}
      assert SystemInfo.cpu_times(@proc) == {:ok, {1360, 9460}}

      assert SystemInfo.meminfo(@proc) ==
               {:ok, %{total_bytes: 4_028_000 * 1024, available_bytes: 2_014_000 * 1024}}
    end

    test "CPU busy is the share of the time between two readings" do
      assert SystemInfo.cpu_percent({1360, 9460}, {1460, 9860}) == 25.0
      assert SystemInfo.cpu_percent({1360, 9460}, {1360, 9460}) == nil
      assert SystemInfo.cpu_percent(nil, {1360, 9460}) == nil
    end

    test "is :error where there is no /proc, or it does not parse" do
      missing = Path.join(System.tmp_dir!(), "no-proc-#{System.unique_integer([:positive])}")
      assert SystemInfo.loadavg(missing) == :error
      assert SystemInfo.cpu_times(missing) == :error
      assert SystemInfo.meminfo(missing) == :error

      garbled = Path.join(System.tmp_dir!(), "garbled-proc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(garbled)
      on_exit(fn -> File.rm_rf!(garbled) end)
      File.write!(Path.join(garbled, "loadavg"), "high\n")
      File.write!(Path.join(garbled, "stat"), "intr 1 2 3\n")
      File.write!(Path.join(garbled, "meminfo"), "MemFree: 12 kB\n")

      assert SystemInfo.loadavg(garbled) == :error
      assert SystemInfo.cpu_times(garbled) == :error
      assert SystemInfo.meminfo(garbled) == :error
    end

    test "the connection count arrives from a process of its own, and a failing counter is :error" do
      {pid, _table} = start_collector(connections: fn -> {:ok, 7} end)
      :ok = Collector.tick(pid, @t0 + 5)
      assert eventually(fn -> Collector.report(pid, @t0 + 5).system.connections == {:ok, 7} end)

      {pid, _table} = start_collector(connections: fn -> raise "no endpoint" end)
      :ok = Collector.tick(pid, @t0 + 5)
      assert Collector.report(pid, @t0 + 5).system.connections == :error
    end

    test "a collector without /proc samples the BEAM and leaves the host unmeasured" do
      {pid, _table} = start_collector(proc_root: "/no/such/proc")
      :ok = Collector.tick(pid, @t0 + 5)

      system = Collector.report(pid, @t0 + 5).system
      assert system.load == nil
      assert system.memory == nil
      assert system.cpu_percent == nil
      assert system.beam.process_count > 0
    end
  end
end
