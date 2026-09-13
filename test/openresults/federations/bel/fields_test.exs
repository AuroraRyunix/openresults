defmodule OpenResults.Federations.BEL.FieldsTest do
  @moduledoc """
  The allowlist: only what `PairingsEngine.Federations.BEL.Member` and
  `.Parser` actually consume leaves this server about a Belgian player.
  """
  use ExUnit.Case, async: true

  alias OpenResults.Federations.BEL.Fields

  test "keeps only the allowed fields" do
    reduced =
      Fields.reduce(%{
        "national_id" => 12345,
        "last_name" => "Peeters",
        "first_name" => "An",
        "fide_id" => 2_500_123,
        "club" => 130,
        "club_name" => "KGSRL",
        "fed" => "BEL",
        # everything below must never survive `reduce/1`.
        "birthday" => "1990-01-01",
        "died" => false,
        "affiliated" => true,
        "email" => "an.peeters@example.invalid",
        "address" => "Rue de la Paix 1",
        "phone" => "+32 470 00 00 00"
      })

    assert Map.keys(reduced) |> Enum.sort() == Enum.sort(Fields.allowed())

    assert reduced == %{
             national_id: "12345",
             last_name: "Peeters",
             first_name: "An",
             national_rating: nil,
             fide_id: 2_500_123,
             club_number: 130,
             club_name: "KGSRL",
             federation: "BEL"
           }
  end

  test "national_id is coerced to a string, preserving leading zeros as given" do
    assert %{national_id: "007"} = Fields.reduce(%{"national_id" => "007", "last_name" => "Bond"})
  end

  test "club 0 (the platform's no-club sentinel) becomes nil, not a literal 0" do
    assert %{club_number: nil} = Fields.reduce(%{"national_id" => "1", "club" => 0})
  end

  test "missing optional fields default to blank/nil, never crash" do
    assert Fields.reduce(%{"national_id" => "1", "last_name" => "Solo"}) == %{
             national_id: "1",
             last_name: "Solo",
             first_name: "",
             national_rating: nil,
             fide_id: nil,
             club_number: nil,
             club_name: "",
             federation: ""
           }
  end
end
