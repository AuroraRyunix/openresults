defmodule OpenResults.RateLimit do
  @moduledoc """
  A fixed-window counter in ETS, for the one endpoint the public can write to.

  The entry form is unauthenticated by design - a player entering an open has
  no account here and should not need one - which makes it the only door in
  this app somebody can knock on a million times. Everything else is a read
  the caches in front of this server can absorb, or a publish behind a bearer
  token.

  Deliberately not a dependency. `hammer`, `plug_attack` and friends bring
  back-ends, pools and a supervision story for a problem that is one ETS
  table and one counter, and this app's whole point is that it is small
  enough to run beside a chess club's website and be understood by whoever
  inherits it.

  A fixed window rather than a sliding one or a token bucket. A fixed window
  lets twice the limit through across a window boundary, which for form spam
  is a rounding error, and in exchange it is one `update_counter/4` per
  request with no per-key process and nothing to reason about at 3am.

  ## What "one client" means

  The caller chooses the key, and choosing it badly is how a limit becomes a
  denial of service rather than a defence against one. The entry form keys on
  `OpenResultsWeb.ClientAddress.of/1`, not on `conn.remote_ip`: something on
  this box dials the app over loopback, so the peer address is 127.0.0.1 for
  every visitor on earth, and a limit keyed on it would be a single bucket
  that one person could spend for everybody. That module decides which
  forwarded header may be believed and when.

  Whatever a caller keys on must be a stable term, and the same shape every
  time. Two paths through one caller keying on a string and a tuple for the
  same client is two buckets where there should be one.
  """

  use GenServer

  @table __MODULE__

  # Rows expire on their own; this only reclaims the space. Frequent enough
  # that a burst from many addresses does not sit in memory for long, rare
  # enough to be invisible.
  @sweep_ms :timer.minutes(5)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one request against `key` and says whether it is allowed.

  Returns `:ok`, or `{:denied, retry_in_ms}` with the time left in the current
  window - which is what lets the caller tell the person how long to wait
  rather than leaving them to guess.

  The request is counted either way. A client that keeps hammering keeps
  extending nothing: the window still ends when it ends, but there is no
  reward for trying again inside it.
  """
  @spec take(term(), keyword()) :: :ok | {:denied, non_neg_integer()}
  def take(key, opts) do
    limit = Keyword.fetch!(opts, :limit)
    window_ms = Keyword.fetch!(opts, :window_ms)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)

    window = div(now, window_ms)
    ends_at = (window + 1) * window_ms

    # The expiry rides along in the row so the sweeper does not have to know
    # what window any given caller asked for.
    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0, ends_at})

    if count > limit, do: {:denied, ends_at - now}, else: :ok
  end

  @doc """
  Forgets every count. For tests, which would otherwise share one window.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl GenServer
  def init(opts) do
    # Public and named: the counting happens in the request process, so this
    # GenServer exists only to own the table and outlive the requests.
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, opts}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)

    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
