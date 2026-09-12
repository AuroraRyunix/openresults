defmodule OpenResultsWeb.FormatTest do
  @moduledoc """
  `OpenResultsWeb.Format` in isolation, one call at a time - no conn, no
  snapshot, no cache. `OpenResultsWeb.LocaleFormattingTest` is where the same
  behaviour is checked through a real rendered page; this file is where the
  edge cases live, because a unit test can hand this module a malformed
  string directly rather than having to smuggle one through a payload.

  Written for the 2026-09-12 translations audit, findings 2 and 3: every
  score and tiebreak value on the site used `Float.to_string/1`, which never
  writes a comma, and every date was the ISO string the snapshot carried,
  passed through untouched.
  """
  use ExUnit.Case, async: true

  alias OpenResultsWeb.Format

  describe "number/2" do
    test "swaps the point for a comma in nl and fr" do
      assert Format.number("5.5", "nl") == "5,5"
      assert Format.number("5.5", "fr") == "5,5"
      assert Format.number("22.25", "nl") == "22,25"
      assert Format.number("-1.5", "fr") == "-1,5"
      assert Format.number("+0.85", "fr") == "+0,85"
    end

    test "leaves en exactly as it was" do
      assert Format.number("5.5", "en") == "5.5"
      assert Format.number("+0.85", "en") == "+0.85"
    end

    test "a whole number has no point to swap, in any locale" do
      # This is the guarantee that a rating, a FIDE id, a pairing number, a
      # round number or a board number never gains a comma: they are never
      # even routed through `TournamentHTML.number/1`, but if one ever were,
      # there is still nothing here for it to do.
      assert Format.number("17", "nl") == "17"
      assert Format.number("2823", "fr") == "2823"
    end

    test "an unknown locale is treated like en" do
      assert Format.number("5.5", "de") == "5.5"
    end

    test "nil passes through" do
      assert Format.number(nil, "nl") == nil
      assert Format.number(nil, "en") == nil
    end

    test "reads the process's own Gettext locale when none is given" do
      Gettext.put_locale(OpenResultsWeb.Gettext, "fr")
      assert Format.number("5.5") == "5,5"
    after
      Gettext.put_locale(OpenResultsWeb.Gettext, "en")
    end
  end

  describe "date/2" do
    test "day, month name, year - in nl" do
      assert Format.date("2026-08-29", "nl") == "29 augustus 2026"
      assert Format.date("2026-01-01", "nl") == "1 januari 2026"
    end

    test "day, month name, year - in fr, lowercase" do
      assert Format.date("2026-08-29", "fr") == "29 août 2026"
      assert Format.date("2026-01-01", "fr") == "1er janvier 2026"
      assert Format.date("2026-01-02", "fr") == "2 janvier 2026"
    end

    test "en is the ISO string, untouched" do
      assert Format.date("2026-08-29", "en") == "2026-08-29"
    end

    test "a date this cannot parse renders as it arrived rather than raising" do
      assert Format.date("not-a-date", "nl") == "not-a-date"
      assert Format.date("2026-13-40", "fr") == "2026-13-40"
      assert Format.date("", "nl") == ""
    end

    test "nil passes through in every locale" do
      assert Format.date(nil, "nl") == nil
      assert Format.date(nil, "en") == nil
    end

    test "a value that is not a string at all does not raise" do
      assert Format.date(12_345, "nl") == 12_345
    end
  end

  describe "date_range/3" do
    test "the same month is named once" do
      assert Format.date_range("2026-03-01", "2026-03-05", "nl") == "1-5 maart 2026"
      assert Format.date_range("2026-03-01", "2026-03-05", "fr") == "1er-5 mars 2026"
    end

    test "a single-digit span still reads as a range, not one date" do
      assert Format.date_range("2026-08-29", "2026-08-31", "nl") == "29-31 augustus 2026"
    end

    test "different months in the same year name each one, and the year once" do
      assert Format.date_range("2026-08-30", "2026-09-02", "nl") ==
               "30 augustus - 2 september 2026"

      assert Format.date_range("2026-08-30", "2026-09-02", "fr") ==
               "30 août - 2 septembre 2026"
    end

    test "different years spell out the full date on both ends" do
      assert Format.date_range("2026-12-30", "2027-01-02", "nl") ==
               "30 december 2026 - 2 januari 2027"
    end

    test "en keeps rendering the same sentence it always has" do
      assert Format.date_range("2026-03-01", "2026-03-05", "en") == "2026-03-01 to 2026-03-05"
    end

    test "nl and fr fall back to the same sentence en uses when a date will not parse" do
      assert Format.date_range("not-a-date", "2026-03-05", "nl") ==
               "not-a-date tot 2026-03-05"

      assert Format.date_range("2026-03-01", "not-a-date", "fr") ==
               "2026-03-01 au not-a-date"
    end

    test "a non-string end never raises, in any locale" do
      assert Format.date_range("2026-03-01", nil, "nl") == "2026-03-01 tot "
    end
  end
end
