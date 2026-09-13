defmodule OpenResultsWeb.ContrastTest do
  @moduledoc """
  Colour contrast, computed from the theme tokens in `assets/css/app.css`
  with the WCAG 2.2 formula - not judged by eye.

  Every colour this site uses is one of seven tokens (see the comment at the
  top of the stylesheet), which is what makes this decidable: a theme is
  seven hex values, and every pairing the stylesheet actually draws is listed
  below with the ratio it needs. A theme added later is checked the moment
  it is defined; a token changed later fails here if it breaks a pairing.

  Added with the accessibility pass of 2026-09-13, which moved `--withheld`
  in four themes to reach 4.5:1 - see `docs/accessibility-2026-09-13.md`.
  """
  use ExUnit.Case, async: true

  @css Path.expand("../../assets/css/app.css", __DIR__)
  @tokens ~w(bg panel ink quiet rule accent withheld)

  # {what it is, foreground token, background token, the ratio it needs}
  @pairings [
    # Text: 4.5:1 (WCAG 1.4.3). Everything the site writes is on one of the
    # two grounds.
    {"body text", "ink", "bg", 4.5},
    {"body text in a card or a field", "ink", "panel", 4.5},
    {"secondary text: details, table headings, hints, footer", "quiet", "bg", 4.5},
    {"secondary text on a panel", "quiet", "panel", 4.5},
    {"links, current round, errors", "accent", "bg", 4.5},
    {"links in a card", "accent", "panel", 4.5},
    {"withheld: unpublished rounds, uncounted rows, results not in", "withheld", "bg", 4.5},
    {"withheld inside a card", "withheld", "panel", 4.5},
    # Text on a filled accent or ink: the send button, the admin badge, the
    # security tag, the cross-table's black chip, the admin bar.
    {"button and badge text", "bg", "accent", 4.5},
    {"inverted text", "bg", "ink", 4.5},
    # Non-text: 3:1 (WCAG 1.4.11).
    {"the focus ring", "accent", "bg", 3.0},
    {"the focus ring inside a card", "accent", "panel", 3.0},
    {"the edge of a text box or dropdown", "quiet", "bg", 3.0},
    {"the edge of a text box or dropdown on a panel", "quiet", "panel", 3.0}
  ]

  setup_all do
    {:ok, themes: themes(stylesheet())}
  end

  # Comments out, so a brace inside one cannot pass for a rule.
  defp stylesheet, do: Regex.replace(~r{/\*.*?\*/}s, File.read!(@css), "")

  defp rules(css), do: Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, css, capture: :all_but_first)

  test "every theme the picker offers is defined, with all seven tokens", %{themes: themes} do
    assert Map.keys(themes) |> Enum.sort() ==
             Enum.sort(["default", "device dark", "paper", "night", "board", "slate", "contrast"])

    for {name, palette} <- themes do
      assert Enum.sort(Map.keys(palette)) == Enum.sort(@tokens), "#{name} is missing a token"
    end
  end

  test "every pairing the stylesheet draws reaches its WCAG AA ratio, in every theme", %{
    themes: themes
  } do
    failures =
      for {theme, palette} <- themes,
          {what, fg, bg, needed} <- @pairings,
          ratio = ratio(palette[fg], palette[bg]),
          ratio < needed do
        "#{theme}: #{what} (--#{fg} #{palette[fg]} on --#{bg} #{palette[bg]}) is " <>
          "#{Float.round(ratio, 2)}:1, needs #{needed}:1"
      end

    assert failures == [], Enum.join(failures, "\n")
  end

  test "no text box or dropdown is edged in the hairline colour" do
    # `--rule` is 1.3-1.5:1 against the ground: fine for a line between two
    # rows, and not an edge anybody can find a text box by.
    offenders =
      for [selector, body] <- rules(stylesheet()),
          selector =~ ~r/\b(input|select|textarea)\b/,
          body =~ ~r/border(-color)?:[^;]*var\(--rule\)/,
          do: String.trim(selector)

    assert offenders == []
  end

  test "keyboard focus is drawn in the accent, and hidden only where nothing is a control" do
    css = stylesheet()

    assert css =~ ~r/(^|\n):focus-visible\s*\{\s*outline:\s*2px solid var\(--accent\)/

    # The places focus is moved TO by a skip link or a script, which are not
    # things anybody operates. A control on this list is a keyboard user who
    # cannot see where they are.
    hidden =
      for [selector, body] <- rules(css),
          body =~ ~r/outline:\s*(none|0)\s*;/,
          one <- String.split(selector, ","),
          do: String.trim(one)

    assert Enum.sort(hidden) ==
             Enum.sort([
               "#main:focus",
               "#admin-main:focus",
               ".card-dialog:focus",
               ".card-dialog h2:focus",
               ".alarm:focus"
             ])
  end

  test "the formula, against the published reference values" do
    assert_in_delta ratio("#000000", "#ffffff"), 21.0, 0.001
    assert_in_delta ratio("#ffffff", "#ffffff"), 1.0, 0.001
    # The WCAG understanding document's own example: #767676 on white.
    assert_in_delta ratio("#767676", "#ffffff"), 4.54, 0.01
  end

  # ---------------------------------------------------------------------------

  defp themes(css) do
    root = block!(css, ~r/(?:^|\n):root\s*\{([^}]*)\}/)
    # `:root:not(...)` inside the device's own dark-mode query.
    dark = block!(css, ~r/:root:not\(\[data-theme\]\)\s*\{([^}]*)\}/)

    named =
      for [name, body] <-
            Regex.scan(~r/:root\[data-theme="(\w+)"\]\s*\{([^}]*)\}/, css,
              capture: :all_but_first
            ),
          into: %{},
          do: {name, palette(body)}

    Map.merge(named, %{"default" => palette(root), "device dark" => palette(dark)})
  end

  defp block!(css, regex) do
    [body] = Regex.run(regex, css, capture: :all_but_first)
    body
  end

  defp palette(body) do
    for [name, hex] <-
          Regex.scan(~r/--([\w-]+):\s*(#[0-9a-fA-F]{6})\s*;/, body, capture: :all_but_first),
        into: %{},
        do: {name, String.downcase(hex)}
  end

  defp ratio(a, b) do
    [la, lb] = Enum.sort([luminance(a), luminance(b)], :desc)
    (la + 0.05) / (lb + 0.05)
  end

  defp luminance("#" <> hex) do
    [r, g, b] =
      for <<channel::binary-size(2) <- hex>> do
        c = String.to_integer(channel, 16) / 255
        if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end
end
