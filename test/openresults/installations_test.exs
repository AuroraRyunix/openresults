defmodule OpenResults.InstallationsTest do
  use OpenResults.DataCase, async: true

  alias OpenResults.Installations
  alias OpenResults.Installations.Installation

  test "a key is orik_ and 32 random bytes; the row holds only its digest" do
    {:ok, %{installation: installation, key: key}} = Installations.register(%{}, {192, 0, 2, 1})

    assert "orik_" <> encoded = key
    assert byte_size(encoded) == 43
    assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(encoded, padding: false)

    row = Repo.get!(Installation, installation.id)
    assert row.key_hash == :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)

    for {_field, value} <- Map.from_struct(row), is_binary(value) do
      refute value =~ encoded
    end

    # And the struct never prints the digest, so a log of it does not either.
    refute inspect(row) =~ row.key_hash
  end

  test "authenticate finds the installation by its key, whatever its status, and nothing else" do
    {:ok, %{installation: %{id: id}, key: key}} = Installations.register(%{}, nil)

    assert {:ok, %Installation{id: ^id}} = Installations.authenticate(key)
    {:ok, _} = Installations.transition(id, ["active"], "revoked")
    assert {:ok, %Installation{id: ^id, status: "revoked"}} = Installations.authenticate(key)

    assert Installations.authenticate(key <> "x") == :error
    assert Installations.authenticate(String.replace_prefix(key, "orik_", "orix_")) == :error
    assert Installations.authenticate("test-ingest-token") == :error
    assert Installations.authenticate(nil) == :error
  end

  test "two registrations never share an id or a key" do
    results = for _ <- 1..20, do: elem(Installations.register(%{}, nil), 1)
    assert results |> Enum.map(& &1.key) |> Enum.uniq() |> length() == 20
    assert results |> Enum.map(& &1.installation.id) |> Enum.uniq() |> length() == 20
    assert Enum.all?(results, &(&1.installation.id =~ ~r/\Ain_[A-Za-z0-9_-]{10}\z/))
  end

  test "touch writes last seen at most once a minute unless the address changes" do
    {:ok, %{installation: installation}} = Installations.register(%{}, nil)
    t0 = ~U[2026-09-12 12:00:00.000000Z]

    Installations.touch(installation, {192, 0, 2, 1}, t0)
    seen = Repo.get!(Installation, installation.id)
    assert seen.last_seen_at == t0
    assert seen.last_seen_from == "192.0.2.1"

    Installations.touch(seen, {192, 0, 2, 1}, DateTime.add(t0, 30))
    assert Repo.get!(Installation, installation.id).last_seen_at == t0

    Installations.touch(seen, {192, 0, 2, 2}, DateTime.add(t0, 31))
    assert Repo.get!(Installation, installation.id).last_seen_from == "192.0.2.2"
  end

  test "null_addresses_before clears each address against its own timestamp" do
    {:ok, %{installation: installation}} = Installations.register(%{}, {192, 0, 2, 1})
    cutoff = DateTime.add(DateTime.utc_now(), 3600)

    Installations.touch(installation, {192, 0, 2, 2}, DateTime.add(cutoff, 60))

    assert Installations.null_addresses_before(cutoff) == 1
    row = Repo.get!(Installation, installation.id)
    assert row.created_from == nil
    assert row.last_seen_from == "192.0.2.2"
  end
end
