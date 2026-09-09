defmodule OpenResultsWeb.ClientAddressTest do
  @moduledoc """
  Who "one client" is, on a deployment where every request arrives from the
  same place.

  The tunnel dials this app over loopback, so `conn.remote_ip` is 127.0.0.1
  for every visitor on earth and anything keyed on it is keyed on nothing.
  These are the two halves of getting the visitor back: believing the
  forwarded header when the request really came through the tunnel, and not
  believing a word of it when it did not.
  """
  use ExUnit.Case, async: true

  alias OpenResultsWeb.ClientAddress

  # 127.0.0.1, and what the same request looks like when it lands on the IPv6
  # socket production binds.
  @loopback {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}
  @loopback_mapped {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}

  defp request(peer, headers) do
    Enum.reduce(headers, %{Plug.Test.conn(:post, "/") | remote_ip: peer}, fn {name, value},
                                                                             conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
  end

  describe "a request that came through the proxy" do
    test "is the address Cloudflare says it saw" do
      conn = request(@loopback, [{"cf-connecting-ip", "203.0.113.7"}])

      assert ClientAddress.of(conn) == {203, 0, 113, 7}
    end

    test "falls back to the leftmost x-forwarded-for entry, spaces and all" do
      conn = request(@loopback, [{"x-forwarded-for", " 203.0.113.7 , 198.51.100.2,10.0.0.4 "}])

      assert ClientAddress.of(conn) == {203, 0, 113, 7}
    end

    test "prefers cf-connecting-ip, which a client cannot write through" do
      # Cloudflare REPLACES that header with the address it saw and APPENDS
      # to x-forwarded-for, so behind Cloudflare the leftmost entry of the
      # second is whatever the client typed. Order is the whole defence.
      conn =
        request(@loopback, [
          {"cf-connecting-ip", "203.0.113.7"},
          {"x-forwarded-for", "198.51.100.9, 203.0.113.7"}
        ])

      assert ClientAddress.of(conn) == {203, 0, 113, 7}
    end

    test "is understood over IPv6 as well" do
      conn = request(@loopback, [{"cf-connecting-ip", "2001:db8::1"}])

      assert ClientAddress.of(conn) == {8193, 3512, 0, 0, 0, 0, 0, 1}
    end

    test "arrives as the proxy on any of the shapes loopback takes" do
      for peer <- [@loopback, @loopback_v6, @loopback_mapped] do
        conn = request(peer, [{"cf-connecting-ip", "203.0.113.7"}])

        assert ClientAddress.of(conn) == {203, 0, 113, 7},
               "#{inspect(peer)} was not read as local"
      end
    end
  end

  describe "a request that did not" do
    test "is keyed on where it actually came from, header or no header" do
      # Nothing but the tunnel can reach the app's port on this deployment,
      # so a request from anywhere else did not come through it and its
      # forwarded header is a sentence a stranger typed.
      conn = request({203, 0, 113, 9}, [{"cf-connecting-ip", "198.51.100.2"}])

      assert ClientAddress.of(conn) == {203, 0, 113, 9}
    end

    test "is not made local by looking like the mapped form" do
      # ::ffff:8.8.8.8 is a public address wearing the notation the loopback
      # test has to accept. Matching on the prefix alone would trust it.
      conn =
        request({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808}, [{"cf-connecting-ip", "203.0.113.7"}])

      assert ClientAddress.of(conn) == {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808}
    end
  end

  describe "a header worth nothing" do
    test "ends at the peer rather than at nil or at the text itself" do
      # Every one of these used to be a way of keying an entire class of
      # requests onto one bucket, which is the bug being fixed wearing a
      # different hat.
      for value <- ["", "   ", ",", "not-an-address", "1.2.3", "999.1.1.1", "<script>", "::gg"] do
        conn = request(@loopback, [{"cf-connecting-ip", value}])

        assert ClientAddress.of(conn) == @loopback, "#{inspect(value)} became a key of its own"
      end
    end

    test "an absent header is simply the peer" do
      assert ClientAddress.of(request(@loopback, [])) == @loopback
    end

    test "and the answer is an address every time, never a string" do
      # The caller keys on this. One shape in every path, or two spellings of
      # one client are two buckets.
      for headers <- [[], [{"cf-connecting-ip", "203.0.113.7"}], [{"x-forwarded-for", "junk"}]] do
        assert is_tuple(ClientAddress.of(request(@loopback, headers)))
      end
    end
  end
end
