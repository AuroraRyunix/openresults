defmodule OpenResults.AddressBlocks.Block do
  @moduledoc "One address or range refused registration, minting and publishing. See `OpenResults.AddressBlocks`."

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenResults.AddressBlocks.CIDR

  @type t :: %__MODULE__{}

  # A block that outlives the reason for it is how a club's wifi ends up
  # refused for a season. So every block expires, and never later than this.
  @max_days 30

  schema "address_blocks" do
    field :cidr, :string
    field :reason, :string
    field :expires_at, :utc_datetime_usec
    field :created_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The longest a block may last, in days."
  def max_days, do: @max_days

  @doc false
  def changeset(block, attrs, now) do
    block
    |> cast(attrs, [:cidr, :reason, :expires_at, :created_by])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:cidr, :reason, :expires_at, :created_by])
    |> validate_length(:reason, max: 2000)
    |> normalize_cidr()
    |> validate_expiry(now)
  end

  defp normalize_cidr(changeset) do
    case get_change(changeset, :cidr) do
      nil ->
        changeset

      text ->
        case CIDR.parse(text) do
          {:ok, cidr} -> put_change(changeset, :cidr, CIDR.to_string(cidr))
          :error -> add_error(changeset, :cidr, "is not an address or a CIDR range")
        end
    end
  end

  defp validate_expiry(changeset, now) do
    case get_field(changeset, :expires_at) do
      nil ->
        changeset

      expires_at ->
        latest = DateTime.add(now, @max_days * 86_400, :second)

        cond do
          DateTime.compare(expires_at, now) != :gt ->
            add_error(changeset, :expires_at, "must be in the future")

          DateTime.compare(expires_at, latest) == :gt ->
            add_error(changeset, :expires_at, "must be at most #{@max_days} days away")

          true ->
            changeset
        end
    end
  end
end
