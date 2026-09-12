defmodule OpenResults.Reports do
  @moduledoc """
  What the public reports about a tournament page, for the operator to read.

  The one moderation input that needs no account: a player who finds invented
  results under their name, or their email address on a page, has to be able
  to say so from the page itself. A report changes nothing on its own - it
  sits in the admin panel's queue until somebody resolves it.

  Stored with the address it came from, so a flood of reports can be told
  from many people reporting one page, and that address is personal data, so
  `OpenResults.Retention` nulls it after thirty days.

  A takedown does not delete a tournament's reports. They are the record of
  why moderation acted, which is worth more after the page is gone than
  before.
  """

  import Ecto.Query, warn: false

  alias OpenResults.AddressBlocks.CIDR
  alias OpenResults.Repo
  alias OpenResults.Reports.Report

  @doc """
  Stores a report for `slug`. The caller has already checked the tournament is
  one the public can see.
  """
  @spec create(String.t(), map(), :inet.ip_address() | nil) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def create(slug, attrs, address) when is_binary(slug) and is_map(attrs) do
    attrs
    |> Report.submission_changeset()
    |> Ecto.Changeset.put_change(:tournament_slug, slug)
    |> Ecto.Changeset.put_change(:client_address, CIDR.address_to_string(address))
    |> Ecto.Changeset.put_change(:status, "open")
    |> Repo.insert()
  end

  @doc "One report by id, or `nil`."
  @spec get(term()) :: Report.t() | nil
  def get(id) do
    case OpenResults.AddressBlocks.integer_id(id) do
      nil -> nil
      int -> Repo.get(Report, int)
    end
  end

  @doc """
  Reports, newest first. Filters: `status` (`open` | `resolved`), `slug`,
  `limit`, `offset`.
  """
  @spec list(map() | keyword()) :: [Report.t()]
  def list(filters \\ %{}) do
    filters = Map.new(filters)

    from(r in Report, order_by: [desc: r.inserted_at, desc: r.id])
    |> filter(:status, filters)
    |> filter(:slug, filters)
    |> OpenResults.QueryFilters.paginate(filters)
    |> Repo.all()
  end

  defp filter(query, :status, %{status: status}) when not is_nil(status),
    do: where(query, [r], r.status == ^to_string(status))

  defp filter(query, :slug, %{slug: slug}) when is_binary(slug),
    do: where(query, [r], r.tournament_slug == ^slug)

  defp filter(query, _key, _filters), do: query

  @doc """
  Marks a report resolved. `{:error, :already_resolved}` for one that is.
  """
  @spec resolve(term(), String.t(), String.t()) ::
          {:ok, Report.t()} | {:error, :not_found | :already_resolved}
  def resolve(id, resolution, resolved_by) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %Report{status: "resolved"} ->
        {:error, :already_resolved}

      %Report{} = report ->
        report
        |> Ecto.Changeset.change(
          status: "resolved",
          resolution: resolution,
          resolved_by: resolved_by,
          resolved_at: DateTime.utc_now()
        )
        |> Repo.update()
    end
  end

  @doc "Open reports per slug, as a map. For the moderation listing."
  @spec open_counts() :: %{String.t() => pos_integer()}
  def open_counts do
    from(r in Report,
      where: r.status == "open",
      group_by: r.tournament_slug,
      select: {r.tournament_slug, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Nulls the address of every report older than `cutoff`, returning how many."
  @spec null_addresses_before(DateTime.t()) :: non_neg_integer()
  def null_addresses_before(%DateTime{} = cutoff) do
    {count, _} =
      from(r in Report, where: not is_nil(r.client_address) and r.inserted_at < ^cutoff)
      |> Repo.update_all(set: [client_address: nil])

    count
  end
end
