defmodule OpenResultsWeb.Flags do
  @moduledoc """
  A small flag beside a federation code, where the arbiter asked for one.

  The flags are third-party art (`lipis/flag-icons`, MIT - see `NOTICE` and
  `priv/static/flags/LICENSE`), shipped as plain static SVG files, one per
  country, and loaded with `<img>`: never inlined, never compiled into this
  code. A table of two hundred players points at the same few files, the
  browser fetches each once, and `loading="lazy"` keeps the ones below the
  fold from being fetched at all.

  ## Which flag

  A federation is FIDE's three-letter code, which is not ISO 3166 (`GER`,
  `NED`, `SUI`, and `ENG`/`SCO`/`WLS`, which ISO does not have at all). The
  table below maps the codes FIDE uses to the file that draws them. A code
  that is not in it draws **no flag** and keeps its text: `FID` (a player
  under the FIDE flag has, by definition, no country to draw), a federation
  that no longer exists, a typo. A wrong flag is worse than none.

  ## When

  Only when the snapshot says so: `tournament.display.flags` must be `true`.
  **Absent means off** - the one display key besides `rounds_played` read
  that way. Every other key hides something an arbiter already publishes, so
  absent must mean shown; this one adds a picture to pages published before
  it existed, and an arbiter's app that has never heard of flags has not
  asked for any. See `OpenResultsWeb.Tournament.flags?/1`.

  The image is decorative (`alt=""`) wherever the code is printed beside it.
  Where only the flag is drawn - a small live-board tile, and since
  2026-10-11 before the name on the standings, the pairings, the cross-table
  and the team pages (`name_flag/1`) - the code is its `alt`, so nobody is
  told less than the picture says. A row that prints the code in a column of
  its own gets one flag, in that column.
  """
  use Phoenix.Component

  # FIDE federation code -> the file under priv/static/flags (ISO 3166-1
  # alpha-2, or flag-icons' own names for the home nations).
  @table ~w(
    AFG:af AHO:cw ALB:al ALG:dz AND:ad ANG:ao ANT:ag ARG:ar ARM:am ARU:aw AUS:au AUT:at
    AZE:az BAH:bs BAN:bd BAR:bb BDI:bi BEL:be BEN:bj BER:bm BHU:bt BIH:ba BIZ:bz BLR:by
    BOL:bo BOT:bw BRA:br BRN:bh BRU:bn BUL:bg BUR:bf CAF:cf CAM:kh CAN:ca CAY:ky CGO:cg
    CHA:td CHI:cl CHN:cn CIV:ci CMR:cm COD:cd COK:ck COL:co COM:km CPV:cv CRC:cr CRO:hr
    CUB:cu CUR:cw CYP:cy CZE:cz DEN:dk DJI:dj DMA:dm DOM:do ECU:ec EGY:eg ENG:gb-eng ERI:er
    ESA:sv ESP:es EST:ee ETH:et FAI:fo FIJ:fj FIN:fi FRA:fr FSM:fm GAB:ga GAM:gm GBS:gw
    GCI:gg GEO:ge GEQ:gq GER:de GHA:gh GRE:gr GRL:gl GRN:gd GUA:gt GUI:gn GUM:gu GUY:gy
    HAI:ht HKG:hk HON:hn HUN:hu INA:id IND:in IOM:im IRI:ir IRL:ie IRQ:iq ISL:is ISR:il
    ISV:vi ITA:it IVB:vg JAM:jm JCI:je JOR:jo JPN:jp KAZ:kz KEN:ke KGZ:kg KIR:ki KOR:kr
    KOS:xk KSA:sa KUW:kw LAO:la LAT:lv LBA:ly LBN:lb LBR:lr LCA:lc LES:ls LIE:li LTU:lt
    LUX:lu MAC:mo MAD:mg MAR:ma MAS:my MAW:mw MDA:md MDV:mv MEX:mx MGL:mn MHL:mh MKD:mk
    MLI:ml MLT:mt MNC:mc MNE:me MOZ:mz MRI:mu MTN:mr MYA:mm NAM:na NCA:ni NCL:nc NED:nl
    NEP:np NGR:ng NIG:ne NOR:no NRU:nr NZL:nz OMA:om PAK:pk PAN:pa PAR:py PER:pe PHI:ph
    PLE:ps PLW:pw PNG:pg POL:pl POR:pt PRK:kp PUR:pr QAT:qa ROU:ro RSA:za RUS:ru RWA:rw
    SAM:ws SCO:gb-sct SEN:sn SEY:sc SGP:sg SKN:kn SLE:sl SLO:si SMR:sm SOL:sb SOM:so SRB:rs
    SRI:lk SSD:ss STP:st SUD:sd SUI:ch SUR:sr SVK:sk SWE:se SWZ:sz SYR:sy TAN:tz TGA:to
    THA:th TJK:tj TKM:tm TLS:tl TOG:tg TPE:tw TTO:tt TUN:tn TUR:tr TUV:tv UAE:ae UGA:ug
    UKR:ua URU:uy USA:us UZB:uz VAN:vu VEN:ve VIE:vn VIN:vc WLS:gb-wls YEM:ye ZAM:zm ZIM:zw
  )
         |> Map.new(fn pair ->
           [fide, file] = String.split(pair, ":")
           {fide, file}
         end)

  @doc "FIDE code -> file name (without `.svg`), for every federation with a flag."
  def table, do: @table

  @doc """
  The path of the flag for a FIDE federation code, or nil when there is none
  to draw. Case and surrounding space are forgiven; anything else is not
  guessed at.
  """
  def path(code) when is_binary(code) do
    case Map.get(@table, code |> String.trim() |> String.upcase()) do
      nil -> nil
      file -> "/flags/" <> file <> ".svg"
    end
  end

  def path(_other), do: nil

  @doc "`path/1` when flags are on, nil otherwise."
  def path(code, true), do: path(code)
  def path(_code, _off), do: nil

  @doc """
  The flag alone. `code` is the FIDE code; nothing renders when it has no
  flag. `alt` is empty unless `label` asks for the code as the picture's text
  (where the code is not printed beside it).
  """
  attr :code, :any, default: nil
  attr :src, :string, default: nil, doc: "a path already resolved by `path/2`, instead of `code`"
  attr :label, :boolean, default: false
  attr :class, :any, default: nil

  def flag(assigns) do
    assigns = assign(assigns, :src, assigns.src || path(assigns.code))

    ~H"""
    <img
      :if={@src}
      class={["flag", @class]}
      src={@src}
      width="20"
      height="15"
      alt={if(@label && is_binary(@code), do: @code |> String.trim() |> String.upcase(), else: "")}
      loading="lazy"
      decoding="async"
    />
    """
  end

  @doc """
  The flag before a player's name, on the pages that print a name and no
  federation code: the standings, the pairings, the cross-table, a team's
  roster. Which turned out to be the pages people look at (2026-10-11).

  Nothing at all when `on` is false. When it is true, every name gets the
  same width in front of it: the flag, or - for `FID`, an unknown code, a
  player with none - an empty box of the same size, so a column of names
  stays a column. The picture's text is the code, because on these pages it
  is printed nowhere else; a row that already has a code column does not use
  this (it has `fed/1`), so nobody hears "BEL" twice.
  """
  attr :code, :any, default: nil
  attr :on, :boolean, default: false

  def name_flag(assigns) do
    assigns = assign(assigns, :src, assigns.on && path(assigns.code))

    ~H"""
    <.flag :if={@src} src={@src} code={@code} label class="flag-name" /><span
      :if={@on && !@src}
      class="flag flag-name flag-none"
      aria-hidden="true"
    ></span>
    """
  end

  @doc """
  A federation as a table cell prints it: the flag (when `on`), then the
  code; a dash when the player has none.
  """
  attr :code, :any, default: nil
  attr :on, :boolean, default: false

  def fed(assigns) do
    ~H"""
    <span :if={@code not in [nil, ""]} class="fed"><.flag :if={@on} code={@code} />{@code}</span>
    <span :if={@code in [nil, ""]}>-</span>
    """
  end
end
