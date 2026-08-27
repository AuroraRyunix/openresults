defmodule OpenResults.SnapshotsTest do
  use OpenResults.DataCase, async: true

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  defp slug_of(payload), do: payload["tournament"]["slug"]

  describe "ingest/2 storing the document" do
    test "keeps the payload whole and verbatim" do
      payload = SnapshotPayloads.swiss()

      assert {:ok, snapshot} = Snapshots.ingest(payload)
      assert snapshot.payload == payload
    end

    test "lifts the envelope into columns and stamps the server clock" do
      payload = SnapshotPayloads.swiss()

      assert {:ok, snapshot} = Snapshots.ingest(payload)
      assert snapshot.tournament_slug == slug_of(payload)
      assert snapshot.version == payload["version"]
      assert snapshot.source_app == payload["source"]["app"]
      assert snapshot.source_version == payload["source"]["version"]
      assert DateTime.to_iso8601(snapshot.published_at) == payload["published_at"]
      assert %DateTime{} = snapshot.received_at
    end

    test "stores a keizer tournament the same way as a swiss one" do
      payload = SnapshotPayloads.keizer()

      assert {:ok, snapshot} = Snapshots.ingest(payload)
      assert snapshot.payload == payload
      # The renderer keys off `system`; this app does not branch on it at all.
      assert snapshot.payload["tournament"]["system"] == "keizer"
    end

    test "survives an envelope with no source object" do
      payload = SnapshotPayloads.swiss() |> Map.delete("source")

      assert {:ok, snapshot} = Snapshots.ingest(payload)
      assert snapshot.source_app == nil
      assert snapshot.source_version == nil
    end

    test "a round the arbiter withheld stays absent" do
      payload = SnapshotPayloads.swiss()
      published = Enum.map(payload["rounds"], & &1["number"])

      assert {:ok, snapshot} = Snapshots.ingest(payload)

      # The fixture withholds a round in the middle, so the numbers published
      # are not a contiguous run. Nothing here fills the gap in, flags it, or
      # notices it: withholding was decided on the arbiter's machine and this
      # server was simply never told about the missing round.
      assert Enum.map(snapshot.payload["rounds"], & &1["number"]) == published
      refute published == Enum.to_list(1..length(published))
    end

    test "non-ASCII player names survive the round trip through SQLite" do
      payload = SnapshotPayloads.swiss()
      names = Enum.map(payload["players"], & &1["name"])

      assert {:ok, snapshot} = Snapshots.ingest(payload)
      assert Enum.map(snapshot.payload["players"], & &1["name"]) == names
      # Diacritics, digraphs and combining marks are ordinary in a European
      # entry list, and a payload stored as JSON text is exactly where an
      # encoding assumption would quietly mangle them.
      assert Enum.any?(names, &(String.length(&1) != byte_size(&1)))
    end

    test "drops a published_at the arbiter's laptop mangled, without failing" do
      payload = Map.put(SnapshotPayloads.swiss(), "published_at", "yesterday-ish")

      assert {:ok, snapshot} = Snapshots.ingest(payload)
      assert snapshot.published_at == nil
      # The unusable string is still in the document for anyone diagnosing it.
      assert snapshot.payload["published_at"] == "yesterday-ish"
    end
  end

  describe "ingest/2 tolerance of unknown fields" do
    test "accepts and stores fields this server has never heard of" do
      payload = SnapshotPayloads.swiss() |> SnapshotPayloads.from_the_future()

      assert {:ok, snapshot} = Snapshots.ingest(payload)

      # Not merely accepted - carried, at every depth. An OpenPairings that
      # grows a field must be able to publish to this server unchanged, which
      # is the whole reason the payload is stored rather than shredded.
      assert snapshot.payload == payload
      assert snapshot.payload["broadcast"] == %{"lichess" => "abcd1234"}
      assert snapshot.payload["unknown_top_level"] == "kept anyway"
      assert snapshot.payload["tournament"]["time_control"] == "90+30"
      assert hd(snapshot.payload["players"])["birth_year"] == 1990
      assert hd(hd(snapshot.payload["rounds"])["boards"])["move_count"] == 41
      assert hd(snapshot.payload["standings"]["rows"])["performance"] == 2650
    end

    test "the known fields still land in their columns alongside the unknown ones" do
      payload = SnapshotPayloads.swiss() |> SnapshotPayloads.from_the_future()

      assert {:ok, snapshot} = Snapshots.ingest(payload)
      assert snapshot.tournament_slug == slug_of(payload)
      assert snapshot.source_app == payload["source"]["app"]
    end
  end

  describe "ingest/2 rejection" do
    test "refuses a payload claiming another schema" do
      payload = Map.put(SnapshotPayloads.swiss(), "schema", "openresults/registration")

      assert {:error, :wrong_schema} = Snapshots.ingest(payload)
    end

    test "refuses a payload with no schema at all" do
      payload = Map.delete(SnapshotPayloads.swiss(), "schema")

      assert {:error, :wrong_schema} = Snapshots.ingest(payload)
    end

    test "refuses an envelope version it has not been taught" do
      for version <- [2, 0, "1", nil] do
        payload = Map.put(SnapshotPayloads.swiss(), "version", version)

        assert {:error, :unknown_version} = Snapshots.ingest(payload)
      end
    end

    test "refuses a payload with no usable slug" do
      base = SnapshotPayloads.swiss()

      broken = [
        Map.delete(base, "tournament"),
        put_in(base, ["tournament"], %{"name" => "Nameless"}),
        put_in(base, ["tournament", "slug"], ""),
        put_in(base, ["tournament", "slug"], "   "),
        put_in(base, ["tournament", "slug"], nil),
        put_in(base, ["tournament", "slug"], 42),
        # A `tournament` that is not an object at all must not crash the walk.
        Map.put(base, "tournament", "gent-spring-open-2026")
      ]

      for payload <- broken do
        assert {:error, :missing_slug} = Snapshots.ingest(payload)
      end
    end

    test "refuses a body that is not an object" do
      assert {:error, :not_an_object} = Snapshots.ingest([1, 2, 3])
      assert {:error, :not_an_object} = Snapshots.ingest("a string")
    end

    test "nothing is stored when the envelope is refused" do
      payload = Map.put(SnapshotPayloads.swiss(), "version", 99)

      assert {:error, :unknown_version} = Snapshots.ingest(payload)
      assert Snapshots.history(slug_of(payload)) == []
    end
  end

  describe "append rather than replace" do
    test "a republish adds a row and leaves the earlier one readable" do
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.republished(first)
      slug = slug_of(first)

      assert {:ok, _} = Snapshots.ingest(first, received_at: at("2026-03-02T14:00:00.000000Z"))
      assert {:ok, _} = Snapshots.ingest(second, received_at: at("2026-03-02T18:00:00.000000Z"))

      assert [newest, oldest] = Snapshots.history(slug)
      assert newest.payload == second
      assert oldest.payload == first
    end

    test "latest/1 returns the most recent publish" do
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.republished(first)

      {:ok, _} = Snapshots.ingest(first, received_at: at("2026-03-02T14:00:00.000000Z"))
      {:ok, _} = Snapshots.ingest(second, received_at: at("2026-03-02T18:00:00.000000Z"))

      assert Snapshots.latest(slug_of(first)).payload == second
    end

    test "as_of/2 answers what the standings said at 14:00" do
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.republished(first)
      slug = slug_of(first)

      {:ok, _} = Snapshots.ingest(first, received_at: at("2026-03-02T14:00:00.000000Z"))
      {:ok, _} = Snapshots.ingest(second, received_at: at("2026-03-02T18:00:00.000000Z"))

      assert Snapshots.as_of(slug, at("2026-03-02T16:00:00.000000Z")).payload == first
      assert Snapshots.as_of(slug, at("2026-03-02T20:00:00.000000Z")).payload == second
      assert Snapshots.as_of(slug, at("2026-03-02T09:00:00.000000Z")) == nil
    end

    test "an identical republish does not append" do
      payload = SnapshotPayloads.swiss()

      assert {:ok, first} = Snapshots.ingest(payload)
      assert {:ok, second} = Snapshots.ingest(payload)

      # A retry after a timeout means the same thing as the original send, so
      # the history stays a record of what changed.
      assert second.id == first.id
      assert second.received_at == first.received_at
      assert length(Snapshots.history(slug_of(payload))) == 1
    end

    test "two publishes in the same microsecond still order by arrival" do
      first = SnapshotPayloads.swiss()
      second = SnapshotPayloads.republished(first)
      same_instant = at("2026-03-02T14:00:00.000000Z")

      {:ok, _} = Snapshots.ingest(first, received_at: same_instant)
      {:ok, _} = Snapshots.ingest(second, received_at: same_instant)

      assert Snapshots.latest(slug_of(first)).payload == second
    end

    test "tournaments do not see each other's snapshots" do
      swiss = SnapshotPayloads.swiss()
      keizer = SnapshotPayloads.keizer()

      {:ok, _} = Snapshots.ingest(swiss)
      {:ok, _} = Snapshots.ingest(keizer)

      assert Snapshots.latest(slug_of(swiss)).payload == swiss
      assert Snapshots.latest(slug_of(keizer)).payload == keizer
      assert Snapshots.latest("no-such-tournament") == nil
    end
  end

  describe "list_current/0" do
    test "returns one row per tournament, the newest" do
      swiss = SnapshotPayloads.swiss()
      swiss_again = SnapshotPayloads.republished(swiss)
      keizer = SnapshotPayloads.keizer()

      {:ok, _} = Snapshots.ingest(swiss)
      {:ok, _} = Snapshots.ingest(swiss_again)
      {:ok, _} = Snapshots.ingest(keizer)

      current = Snapshots.list_current()

      assert length(current) == 2

      assert Enum.map(current, & &1.tournament_slug) ==
               Enum.sort([slug_of(swiss), slug_of(keizer)])

      assert Enum.find(current, &(&1.tournament_slug == slug_of(swiss))).payload == swiss_again
    end

    test "is empty before anything publishes" do
      assert Snapshots.list_current() == []
    end
  end

  defp at(iso8601) do
    {:ok, datetime, _utc_offset} = DateTime.from_iso8601(iso8601)
    datetime
  end
end
