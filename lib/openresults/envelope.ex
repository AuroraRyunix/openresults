defmodule OpenResults.Envelope do
  @moduledoc """
  The only part of an incoming document this app is allowed to inspect.

  A payload is checked on four things and four things only - that it claims
  the schema being offered, that it claims a version this server understands,
  that it names a tournament, and that it is an object at all. Everything past
  those four is stored uninterpreted.

  That restraint is the contract, not laziness. `docs/snapshot-schema.md`
  promises an OpenPairings 0.17 laptop can publish to a much newer server for
  months, which only holds if the reader ignores what it does not recognise. A
  validator that enumerated known fields would reject the first field a newer
  client added, and the break would land on the arbiter mid-tournament rather
  than on whoever added the field.
  """

  @type error :: :not_an_object | :wrong_schema | :unknown_version | :missing_slug

  @doc """
  Checks the envelope of `payload` and returns the tournament slug.

  `slug_path` is the access path to the slug, which differs between the two
  payloads: a snapshot nests it under `tournament`, a registration carries it
  flat as `tournament_slug`.
  """
  @spec validate(term(), String.t(), [integer()], [String.t()]) ::
          {:ok, String.t()} | {:error, error()}
  def validate(payload, schema_id, supported_versions, slug_path) do
    with :ok <- check_object(payload),
         :ok <- check_schema(payload, schema_id),
         :ok <- check_version(payload, supported_versions) do
      fetch_slug(payload, slug_path)
    end
  end

  defp check_object(payload) when is_map(payload), do: :ok
  defp check_object(_payload), do: {:error, :not_an_object}

  defp check_schema(payload, schema_id) do
    case Map.get(payload, "schema") do
      ^schema_id -> :ok
      _other -> {:error, :wrong_schema}
    end
  end

  defp check_version(payload, supported_versions) do
    # Matched against a list rather than compared to a maximum, because the
    # envelope version only ever changes for a break that cannot be expressed
    # additively. A version this server has not been taught is a version whose
    # meaning it cannot guess, so it is refused rather than assumed compatible.
    if Map.get(payload, "version") in supported_versions do
      :ok
    else
      {:error, :unknown_version}
    end
  end

  defp fetch_slug(payload, slug_path) do
    case dig(payload, slug_path) do
      slug when is_binary(slug) ->
        case String.trim(slug) do
          "" -> {:error, :missing_slug}
          trimmed -> {:ok, trimmed}
        end

      _absent_or_not_a_string ->
        {:error, :missing_slug}
    end
  end

  # `get_in/2` raises when it meets a value that is not a map partway down, and
  # a hostile or broken client can send `"tournament": "gent"` just as easily
  # as the object the contract asks for. A wrong shape has to be a 422, not a
  # 500, so the walk refuses rather than raises.
  defp dig(value, []), do: value
  defp dig(map, [key | rest]) when is_map(map), do: dig(Map.get(map, key), rest)
  defp dig(_not_a_map, _path), do: nil

  @doc """
  Reads the arbiter's own timestamp out of an envelope field.

  Advisory only - a laptop in a playing hall may have any time at all on it,
  so a value that will not parse is dropped rather than being an error. The
  raw string it came from survives inside the stored payload either way.
  """
  @spec claimed_time(map(), String.t()) :: DateTime.t() | nil
  def claimed_time(payload, key) do
    with value when is_binary(value) <- Map.get(payload, key),
         {:ok, datetime, _utc_offset} <- DateTime.from_iso8601(value) do
      DateTime.truncate(datetime, :second)
    else
      _unusable -> nil
    end
  end
end
