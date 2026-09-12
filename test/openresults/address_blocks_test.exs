defmodule OpenResults.AddressBlocksTest do
  use OpenResults.DataCase, async: true

  alias OpenResults.AddressBlocks
  alias OpenResults.AddressBlocks.CIDR

  defp cidr!(text) do
    {:ok, cidr} = CIDR.parse(text)
    cidr
  end

  defp ip!(text) do
    {:ok, ip} = :inet.parse_strict_address(String.to_charlist(text))
    ip
  end

  describe "CIDR, IPv4" do
    test "parses an address as a /32 and a range with its host bits masked" do
      assert CIDR.to_string(cidr!("203.0.113.7")) == "203.0.113.7/32"
      assert CIDR.to_string(cidr!(" 203.0.113.7/24 ")) == "203.0.113.0/24"
      assert CIDR.to_string(cidr!("10.1.2.3/8")) == "10.0.0.0/8"
      assert CIDR.to_string(cidr!("10.1.2.3/0")) == "0.0.0.0/0"
      assert CIDR.to_string(cidr!("203.0.113.255/31")) == "203.0.113.254/31"
    end

    test "matches on the prefix bits and nothing else" do
      range = cidr!("203.0.113.0/24")

      assert CIDR.contains?(range, {203, 0, 113, 0})
      assert CIDR.contains?(range, {203, 0, 113, 255})
      refute CIDR.contains?(range, {203, 0, 112, 255})
      refute CIDR.contains?(range, {203, 0, 114, 0})

      odd = cidr!("198.51.100.64/27")
      assert CIDR.contains?(odd, {198, 51, 100, 64})
      assert CIDR.contains?(odd, {198, 51, 100, 95})
      refute CIDR.contains?(odd, {198, 51, 100, 96})
      refute CIDR.contains?(odd, {198, 51, 100, 63})

      single = cidr!("192.0.2.1")
      assert CIDR.contains?(single, {192, 0, 2, 1})
      refute CIDR.contains?(single, {192, 0, 2, 2})

      assert CIDR.contains?(cidr!("0.0.0.0/0"), {8, 8, 8, 8})
    end

    test "reads a v4-mapped IPv6 address as the IPv4 address it carries, both ways" do
      mapped = ip!("::ffff:203.0.113.9")

      assert CIDR.contains?(cidr!("203.0.113.0/24"), mapped)

      # A v4-mapped range is written with an IPv6 prefix, and means the IPv4
      # range it covers.
      assert CIDR.to_string(cidr!("::ffff:203.0.113.0/120")) == "203.0.113.0/24"
      assert CIDR.contains?(cidr!("::ffff:203.0.113.0/120"), {203, 0, 113, 9})
      refute CIDR.contains?(cidr!("::ffff:203.0.113.0/120"), {203, 0, 114, 9})
      assert CIDR.parse("::ffff:203.0.113.0/64") == :error

      assert CIDR.to_string(cidr!("::ffff:203.0.113.9")) == "203.0.113.9/32"
      assert CIDR.contains?(cidr!("::ffff:203.0.113.9"), {203, 0, 113, 9})
      assert CIDR.address_to_string(mapped) == "203.0.113.9"
    end
  end

  describe "CIDR, IPv6" do
    test "parses and canonicalises" do
      assert CIDR.to_string(cidr!("2001:db8::1")) == "2001:db8::1/128"
      assert CIDR.to_string(cidr!("2001:DB8:aa:bb:cc::1/48")) == "2001:db8:aa::/48"
      assert CIDR.to_string(cidr!("::/0")) == "::/0"
    end

    test "matches across the 64-bit boundary and at odd prefixes" do
      range = cidr!("2001:db8:aa:bb::/64")
      assert CIDR.contains?(range, ip!("2001:db8:aa:bb:ffff:ffff:ffff:ffff"))
      refute CIDR.contains?(range, ip!("2001:db8:aa:bc::"))

      odd = cidr!("2001:db8:8000::/33")
      assert CIDR.contains?(odd, ip!("2001:db8:ffff::1"))
      refute CIDR.contains?(odd, ip!("2001:db8:7fff::1"))

      high = cidr!("2001:db8::ff00/120")
      assert CIDR.contains?(high, ip!("2001:db8::ffff"))
      refute CIDR.contains?(high, ip!("2001:db8::feff"))
    end

    test "families never match each other" do
      refute CIDR.contains?(cidr!("::/0"), {203, 0, 113, 9})
      refute CIDR.contains?(cidr!("0.0.0.0/0"), ip!("2001:db8::1"))
    end
  end

  describe "CIDR, rubbish" do
    test "is :error, including the abbreviated forms inet_aton tolerates" do
      for text <- [
            "",
            " ",
            "203.0.113",
            "1",
            "203.0.113.0/",
            "203.0.113.0/33",
            "2001:db8::/129",
            "203.0.113.0/-1",
            "203.0.113.0/8/8",
            "example.com",
            "203.0.113.0/2x",
            nil,
            42
          ] do
        assert CIDR.parse(text) == :error, inspect(text)
      end

      refute CIDR.contains?(cidr!("0.0.0.0/0"), "not an address")
      refute CIDR.contains?(cidr!("0.0.0.0/0"), nil)
    end
  end

  describe "blocks" do
    test "blocked? only while a block is live" do
      now = ~U[2026-09-12 12:00:00.000000Z]

      {:ok, _} =
        AddressBlocks.create("203.0.113.0/24", DateTime.add(now, 3600), "x", "a@b.c", now)

      assert AddressBlocks.blocked?({203, 0, 113, 1}, now)
      refute AddressBlocks.blocked?({203, 0, 114, 1}, now)
      refute AddressBlocks.blocked?({203, 0, 113, 1}, DateTime.add(now, 3600))

      assert AddressBlocks.remove_expired(DateTime.add(now, 3599)) == 0
      assert AddressBlocks.remove_expired(DateTime.add(now, 3600)) == 1
      assert AddressBlocks.list_active(now) == []
    end

    test "a block at exactly 30 days is allowed, a second more is not" do
      now = ~U[2026-09-12 12:00:00.000000Z]

      assert {:ok, _} =
               AddressBlocks.create(
                 "192.0.2.1",
                 DateTime.add(now, 30 * 86_400),
                 "x",
                 "a@b.c",
                 now
               )

      assert {:error, changeset} =
               AddressBlocks.create(
                 "192.0.2.1",
                 DateTime.add(now, 30 * 86_400 + 1),
                 "x",
                 "a@b.c",
                 now
               )

      assert "must be at most 30 days away" in errors_on(changeset).expires_at
    end
  end
end
