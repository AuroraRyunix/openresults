defmodule OpenResults.AddressBlocks do
  @moduledoc """
  Addresses refused registration, minting and publishing.

  Blunt, and deliberately so. A club's wifi or a mobile carrier puts many
  people behind one address, so a block reaches everybody there - which is why
  every block expires (at most 30
  days), carries a reason, and why the admin panel shows how many
  installations were seen from an address before it is confirmed
  (`OpenResults.Moderation.installations_seen_from/1`).

  What a block does NOT touch: reading any page, the entry form, the report
  form, deleting a tournament, or anything done with the operator token. It is
  a brake on handing out and using public credentials, not a firewall.

  Checked by loading the live blocks and matching in Elixir, rather than in
  SQL. CIDR on text columns is not something SQLite can index, the table holds
  a handful of rows that expire within a month, and the check runs only on the
  three write paths an installation can reach.
  """

  import Ecto.Query, warn: false

  alias OpenResults.AddressBlocks.Block
  alias OpenResults.AddressBlocks.CIDR
  alias OpenResults.Repo

  @doc """
  Creates a block. `expires_at` must be in the future and at most
  30 days away.
  """
  @spec create(String.t(), DateTime.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def create(ip_or_cidr, expires_at, reason, created_by, now \\ DateTime.utc_now()) do
    %Block{}
    |> Block.changeset(
      %{cidr: ip_or_cidr, expires_at: expires_at, reason: reason, created_by: created_by},
      now
    )
    |> Repo.insert()
  end

  @doc "Every block that has not expired, soonest to expire first."
  @spec list_active(DateTime.t()) :: [Block.t()]
  def list_active(now \\ DateTime.utc_now()) do
    from(b in Block, where: b.expires_at > ^now, order_by: [asc: b.expires_at, asc: b.id])
    |> Repo.all()
  end

  @doc "One block by id, or `nil`."
  @spec get(term()) :: Block.t() | nil
  def get(id) do
    case integer_id(id) do
      nil -> nil
      int -> Repo.get(Block, int)
    end
  end

  @doc "Removes a block."
  @spec delete(Block.t()) :: {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Block{} = block), do: Repo.delete(block)

  @doc """
  Is `address` inside any live block? `address` is an `:inet` tuple, as
  `OpenResultsWeb.ClientAddress.of/1` returns it.
  """
  @spec blocked?(:inet.ip_address(), DateTime.t()) :: boolean()
  def blocked?(address, now \\ DateTime.utc_now()) do
    now
    |> list_active()
    |> Enum.any?(fn %Block{cidr: text} ->
      case CIDR.parse(text) do
        {:ok, cidr} -> CIDR.contains?(cidr, address)
        :error -> false
      end
    end)
  end

  @doc "Deletes every block that has expired, returning how many went."
  @spec remove_expired(DateTime.t()) :: non_neg_integer()
  def remove_expired(now \\ DateTime.utc_now()) do
    {count, _} = from(b in Block, where: b.expires_at <= ^now) |> Repo.delete_all()
    count
  end

  @doc false
  def integer_id(id) when is_integer(id), do: id

  def integer_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _not_an_id -> nil
    end
  end

  def integer_id(_other), do: nil
end
