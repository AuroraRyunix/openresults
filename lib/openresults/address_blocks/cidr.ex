defmodule OpenResults.AddressBlocks.CIDR do
  @moduledoc """
  An address or an address range, and whether an address falls inside it.

  `:inet` for the parsing and integer arithmetic for the matching, because the
  whole of CIDR is "do the first N bits agree" and that is one shift. No
  dependency: a library for this would be larger than the problem.

  ## IPv4 behind IPv6

  An IPv4 client reaching a socket bound to `::` arrives as the v4-mapped
  address `::ffff:a.b.c.d` - `OpenResultsWeb.ClientAddress` says the same about
  loopback. So a v4-mapped address, whether it is being blocked or being
  checked, is read as the IPv4 address it carries. Otherwise a block on
  `203.0.113.0/24` would never match a client the socket reported in its IPv6
  spelling, and a block would be exactly as effective as the listener's
  address family happened to allow.
  """

  import Bitwise

  @enforce_keys [:family, :network, :prefix]
  defstruct [:family, :network, :prefix]

  @type family :: :inet | :inet6
  @type t :: %__MODULE__{family: family(), network: non_neg_integer(), prefix: non_neg_integer()}

  @doc """
  Parses `"203.0.113.7"`, `"203.0.113.0/24"`, `"2001:db8::1"` or
  `"2001:db8::/32"`.

  Host bits beyond the prefix are masked off rather than refused, so
  `203.0.113.7/24` is `203.0.113.0/24` - which is what whoever typed it meant.
  Whitespace around the value is ignored. Anything else is `:error`, including
  the abbreviated forms `inet_aton(3)` tolerates, for the reason
  `OpenResultsWeb.ClientAddress` refuses them.
  """
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(text) when is_binary(text) do
    case text |> String.trim() |> String.split("/") do
      [address] -> build(address, nil)
      [address, prefix] -> build(address, prefix)
      _more_slashes -> :error
    end
  end

  def parse(_not_text), do: :error

  defp build(address, prefix_text) do
    with {:ok, ip} <- parse_address(address),
         {family, value, bits} <- to_integer(ip),
         {:ok, prefix} <- parse_prefix(prefix_text, prefix_bits(ip, bits)),
         {:ok, prefix} <- mapped_prefix(ip, prefix) do
      {:ok, %__MODULE__{family: family, network: mask(value, bits, prefix), prefix: prefix}}
    else
      _invalid -> :error
    end
  end

  defp parse_address(""), do: :error

  defp parse_address(address) do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  # A v4-mapped range is written with an IPv6 prefix - `::ffff:203.0.113.0/120`
  # is `203.0.113.0/24` - so its prefix is read against 128 bits and then
  # brought down to the 32 bits it actually covers. Below /96 it would be
  # covering IPv6 addresses that are not v4-mapped at all, which is not a
  # range this reading can represent, so that is refused.
  defp prefix_bits({0, 0, 0, 0, 0, 0xFFFF, _, _}, _bits), do: 128
  defp prefix_bits(_ip, bits), do: bits

  defp mapped_prefix({0, 0, 0, 0, 0, 0xFFFF, _, _}, prefix) when prefix >= 96,
    do: {:ok, prefix - 96}

  defp mapped_prefix({0, 0, 0, 0, 0, 0xFFFF, _, _}, _below_96), do: :error
  defp mapped_prefix(_ip, prefix), do: {:ok, prefix}

  defp parse_prefix(nil, bits), do: {:ok, bits}

  defp parse_prefix(text, bits) do
    case Integer.parse(text) do
      {prefix, ""} when prefix >= 0 and prefix <= bits -> {:ok, prefix}
      _not_a_prefix -> :error
    end
  end

  @doc """
  Does `cidr` contain `address`? `address` is an `:inet` tuple or a string.

  Families never match each other, apart from the v4-mapped rule in the
  moduledoc: `::/0` does not contain every IPv4 address.
  """
  @spec contains?(t(), :inet.ip_address() | String.t()) :: boolean()
  def contains?(%__MODULE__{} = cidr, address) when is_binary(address) do
    case parse_address(String.trim(address)) do
      {:ok, ip} -> contains?(cidr, ip)
      :error -> false
    end
  end

  def contains?(%__MODULE__{family: family, network: network, prefix: prefix}, address)
      when is_tuple(address) do
    case to_integer(address) do
      {^family, value, bits} -> mask(value, bits, prefix) == network
      _other_family_or_invalid -> false
    end
  end

  def contains?(%__MODULE__{}, _not_an_address), do: false

  @doc "The canonical text: `203.0.113.0/24`, `2001:db8::/32`, `198.51.100.7/32`."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{family: family, network: network, prefix: prefix}) do
    "#{network |> from_integer(family) |> :inet.ntoa()}/#{prefix}"
  end

  @doc """
  An address as text, with a v4-mapped IPv6 address written as the IPv4
  address it is. What gets stored as "created from" and "last seen from", so
  that one client is one spelling.
  """
  @spec address_to_string(:inet.ip_address()) :: String.t() | nil
  def address_to_string(address) when is_tuple(address) do
    case to_integer(address) do
      {family, value, _bits} -> value |> from_integer(family) |> :inet.ntoa() |> List.to_string()
      :error -> nil
    end
  end

  def address_to_string(_not_an_address), do: nil

  # The IPv4 address inside ::ffff:a.b.c.d, as a 32-bit family member.
  defp to_integer({0, 0, 0, 0, 0, 0xFFFF, high, low})
       when high in 0..0xFFFF and low in 0..0xFFFF do
    {:inet, (high <<< 16) + low, 32}
  end

  defp to_integer({a, b, c, d} = ip)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: {:inet, ip |> Tuple.to_list() |> fold(8), 32}

  defp to_integer({_, _, _, _, _, _, _, _} = ip) do
    parts = Tuple.to_list(ip)

    if Enum.all?(parts, &(is_integer(&1) and &1 in 0..0xFFFF)),
      do: {:inet6, fold(parts, 16), 128},
      else: :error
  end

  defp to_integer(_not_an_address), do: :error

  defp fold(parts, width), do: Enum.reduce(parts, 0, fn part, acc -> (acc <<< width) + part end)

  defp from_integer(value, :inet), do: split(value, 4, 8) |> List.to_tuple()
  defp from_integer(value, :inet6), do: split(value, 8, 16) |> List.to_tuple()

  defp split(value, count, width) do
    mask = (1 <<< width) - 1
    for index <- (count - 1)..0//-1, do: value >>> (index * width) &&& mask
  end

  # The top `prefix` bits of a `bits`-wide value. Shifting right then left
  # rather than building a mask, so a `/0` is simply zero and needs no case.
  defp mask(value, bits, prefix), do: (value >>> (bits - prefix)) <<< (bits - prefix)
end
