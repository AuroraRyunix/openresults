defmodule OpenResults.RegistrationsTest do
  use OpenResults.DataCase, async: true

  alias OpenResults.Registrations
  alias OpenResults.SnapshotPayloads

  describe "ingest/2" do
    test "accepts and holds an entry whole" do
      payload = SnapshotPayloads.registration()

      assert {:ok, registration} = Registrations.ingest(payload)
      assert registration.tournament_slug == payload["tournament_slug"]
      assert registration.version == payload["version"]
      assert registration.payload == payload
    end

    test "keeps the email, which is the point of the table" do
      payload = SnapshotPayloads.registration()

      assert {:ok, registration} = Registrations.ingest(payload)
      assert registration.payload["player"]["email"] == payload["player"]["email"]
    end

    test "stamps its own received_at and does not trust the envelope's" do
      payload = Map.put(SnapshotPayloads.registration(), "received_at", "1999-01-01T00:00:00Z")
      stamped = ~U[2026-02-01 09:12:00.000000Z]

      assert {:ok, registration} = Registrations.ingest(payload, received_at: stamped)
      assert registration.received_at == stamped
      # The submitter's claim survives inside the payload, unpromoted.
      assert registration.payload["received_at"] == "1999-01-01T00:00:00Z"
    end

    test "tolerates fields a newer form added" do
      payload =
        SnapshotPayloads.registration()
        |> Map.put("referral", "poster in the club")
        |> update_in(["player"], &Map.put(&1, "phone", "0470 00 00 00"))

      assert {:ok, registration} = Registrations.ingest(payload)
      assert registration.payload == payload
    end

    test "refuses a snapshot posted at the registration path" do
      assert {:error, :wrong_schema} = Registrations.ingest(SnapshotPayloads.swiss())
    end

    test "refuses an unknown version and a missing slug" do
      base = SnapshotPayloads.registration()

      assert {:error, :unknown_version} = Registrations.ingest(Map.put(base, "version", 2))
      assert {:error, :missing_slug} = Registrations.ingest(Map.delete(base, "tournament_slug"))
      assert {:error, :missing_slug} = Registrations.ingest(Map.put(base, "tournament_slug", ""))
    end
  end

  describe "list_for_tournament/1" do
    test "returns entries oldest first, because entry order decides a capped field" do
      base = SnapshotPayloads.registration()
      early = put_in(base, ["player", "name"], "Early, Bird")
      late = put_in(base, ["player", "name"], "Late, Comer")

      {:ok, _} = Registrations.ingest(late, received_at: ~U[2026-02-02 10:00:00.000000Z])
      {:ok, _} = Registrations.ingest(early, received_at: ~U[2026-02-01 10:00:00.000000Z])

      assert [first, second] = Registrations.list_for_tournament(base["tournament_slug"])
      assert first.payload["player"]["name"] == "Early, Bird"
      assert second.payload["player"]["name"] == "Late, Comer"
    end

    test "does not mix tournaments" do
      base = SnapshotPayloads.registration()
      {:ok, _} = Registrations.ingest(base)

      assert Registrations.list_for_tournament("some-other-open") == []
    end
  end
end
