defmodule OpenResults.Registrations.Entry do
  @moduledoc """
  What the public entry form accepts, and the payload it becomes.

  Deliberately separate from `OpenResults.Registrations.ingest/2`. That
  function is tolerant on purpose - a newer form posting a field this server
  has never seen is stored rather than refused, which is the same rule the
  snapshot side follows and the reason the contract can grow. This module is
  the opposite: it is the strict half, and it is strict because the thing on
  the other end of it is a person.

  A member of the public gets one attempt at this form and no way to correct
  it afterwards. So a rating with a letter in it, an email with no `@` and a
  bye requested for a round that does not exist all have to be said out loud
  *before* anything is stored, in words that name what to change. Once past
  here the entry is contract-shaped and `ingest/2` has nothing left to refuse.

  The fields are exactly the ones `docs/snapshot-schema.md` allows in a
  registration payload and no others. `email` is the only personal data this
  server holds, is never part of a snapshot, and is never rendered.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenResults.Registrations

  @type t :: %__MODULE__{}

  # The registration envelope version this form speaks. Bumped only for a
  # break that cannot be expressed additively - see `OpenResults.Envelope`.
  @version 1

  # Ratings run from a club's lowest floor to well past the world number one.
  # A cap exists so a mistyped year of birth is caught rather than filed.
  @rating_range 0..3500

  # FIDE IDs are digits, currently seven or eight of them. The ceiling is
  # generous on purpose: refusing a real ID because FIDE grew a digit would be
  # this app inventing a rule FIDE did not make.
  @max_fide_id 999_999_999

  # RFC 5321's limit on an address. Anything longer is not a typo, it is a
  # payload.
  @max_email 254

  @primary_key false
  embedded_schema do
    field :name, :string
    field :email, :string
    field :rating, :integer
    field :federation, :string
    field :fide_id, :integer
    field :club, :string
    field :requested_byes, {:array, :integer}
  end

  @fields ~w(name email rating federation fide_id club requested_byes)a

  @doc """
  An untouched form, for the first render.

  No validation has run, so nothing is marked wrong before anybody has typed.
  """
  @spec new() :: Ecto.Changeset.t()
  def new, do: change(%__MODULE__{})

  @doc """
  Validates one submission.

  `rounds` is the tournament's own round list, which is what makes a requested
  bye checkable at all: a bye for round 9 of a five-round open is a mistake
  worth catching here rather than one for the arbiter to puzzle over later.
  Pass `[]` for a tournament whose rounds are not known and the field is not
  offered.
  """
  @spec changeset(map(), [integer()]) :: Ecto.Changeset.t()
  def changeset(attrs, rounds \\ []) do
    %__MODULE__{}
    # `:message` rewrites Ecto's "is invalid", which is true but useless to
    # somebody who typed their rating with a comma in it.
    |> cast(attrs, @fields, message: &cast_message/2)
    |> update_change(:name, &squish/1)
    |> update_change(:club, &squish/1)
    |> update_change(:email, &String.trim/1)
    |> update_change(:federation, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:name],
      message: "please give the name you want on the pairing list"
    )
    |> validate_required([:email],
      message: "the arbiter needs an address to reach you at"
    )
    |> validate_length(:name,
      min: 2,
      max: 100,
      message: "a name is between 2 and 100 characters"
    )
    |> validate_length(:email,
      max: @max_email,
      message: "that is too long to be an email address"
    )
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "that does not look like an email address - check for a missing @ or a typo"
    )
    |> validate_inclusion(:rating, @rating_range,
      message:
        "a rating is a whole number between #{@rating_range.first} and #{@rating_range.last} - leave it empty if you do not have one"
    )
    |> validate_format(:federation, ~r/^[A-Z]{3}$/,
      message: "a federation is a three-letter FIDE code, like BEL or NOR"
    )
    |> validate_number(:fide_id,
      greater_than: 0,
      less_than_or_equal_to: @max_fide_id,
      message: "a FIDE ID is the number on your FIDE profile - digits only"
    )
    |> validate_length(:club,
      max: 100,
      message: "a club name is at most 100 characters"
    )
    |> validate_subset(:requested_byes, rounds, message: bye_message(rounds))
  end

  @doc """
  The entry as the contract carries it.

  Built here rather than in the controller because which fields may travel is
  a statement about `docs/snapshot-schema.md`, not about HTTP. Fields the
  person left empty are omitted rather than sent as `null`: the contract says
  a missing key and a `null` mean the same thing, and the shorter document is
  the one that reads like a paper entry form.

  `received_at` is the server's own clock. On the ingest side that field is a
  claim by an unauthenticated submitter and is not trusted; here the server IS
  the submitter, so the claim and the fact are the same instant, and the same
  one is handed to `ingest/2` so the stored column and the stored document
  cannot disagree.
  """
  @spec to_payload(t(), String.t(), DateTime.t()) :: map()
  def to_payload(%__MODULE__{} = entry, slug, %DateTime{} = received_at) do
    %{
      "schema" => Registrations.schema_id(),
      "version" => @version,
      "received_at" => received_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "tournament_slug" => slug,
      "player" => player(entry)
    }
  end

  defp player(entry) do
    %{
      "name" => entry.name,
      "rating" => entry.rating,
      "federation" => entry.federation,
      "fide_id" => entry.fide_id,
      "club" => entry.club,
      "email" => entry.email,
      "requested_byes" => entry.requested_byes
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
    |> Map.new()
  end

  defp cast_message(:rating, _meta), do: "a rating is a whole number, digits only"
  defp cast_message(:fide_id, _meta), do: "a FIDE ID is a whole number, digits only"
  defp cast_message(:requested_byes, _meta), do: "that is not a list of round numbers"
  defp cast_message(_field, _meta), do: nil

  defp bye_message([]), do: "this tournament is not taking bye requests"

  defp bye_message(rounds) do
    "choose from the rounds this tournament has: #{Enum.join(rounds, ", ")}"
  end

  # Collapses the whitespace a phone keyboard leaves behind. A name is going on
  # a pairing list next to nine others, and "De  Vos,  Ilse" would be the only
  # one with a double space in it.
  defp squish(value) do
    value |> String.trim() |> String.replace(~r/\s+/, " ")
  end
end
