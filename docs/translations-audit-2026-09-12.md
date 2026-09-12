# Translations audit - 2026-09-12

First pass over this dimension. The whole-codebase audit of 2026-09-05 did
not cover translations, and neither had anything else: the catalogues were
born in one commit (`476d095`, 2026-09-08, "Speak Dutch and French") and
every commit that has touched them since is a feature commit that added or
moved strings alongside the code that calls them. `git log --follow` on
`priv/gettext/fr/LC_MESSAGES/default.po` returns eleven commits, and
`priv/gettext/nl/...` and `priv/gettext/en/...` return **the same eleven**,
with the `.pot` moving in lockstep every time. There is no commit anywhere in
this repository whose subject, or whose diff, is a review of a translation.

So the claim this audit was asked to verify holds, and holds wider than it
was put: the French catalogue has never been read as prose by anybody, and
neither has the Dutch one. Both were written by the same author as the
English, in the same sitting as the feature, and never revisited.

Scope: three locales (`en`, `nl`, `fr`), two domains (`default`, `errors`),
208 + 16 messages, the resolution path, the page cache, and the coverage
question - what user-visible English is not in a catalogue at all.

---

## What was found, worst first

### 1. Three validation messages were answered in English on translated pages · FIXED

`lib/openresults_web/components/core_components.ex` · `translate_error/1`

The entry form is the only place on this site where a visitor is told they
got something wrong. Three of its messages rendered in English to every
Dutch and French reader:

- `a name is between 2 and 100 characters`
- `that is too long to be an email address`
- `a club name is at most 100 characters`

All three were present in `errors.pot` and translated in both catalogues the
whole time. The catalogue was never the problem; the **lookup** was.

`Ecto.Changeset.validate_length/3` attaches a `count:` option to the error it
reports, whatever message it was handed, because Ecto's own message is
count-sensitive: `should be at most %{count} character(s)`. The scaffold's
`translate_error/1` read that option as permission to look the message up as
a plural:

```elixir
if count = opts[:count] do
  Gettext.dngettext(OpenResultsWeb.Gettext, "errors", msg, msg, count, opts)
```

Every message on this form is overridden in
`OpenResults.Registrations.Entry` with a sentence that names its own limit,
carries no `%{count}`, and is therefore a **singular** entry in the
catalogue - which is the right shape for it. Gettext keys plural messages by
`{msgid, msgid_plural}` and does not fall back to the singular catalogue, so
the lookup missed, gettext interpolated the English msgid, and returned it.

Measured before the fix, at locale `fr`:

```
club:  "a club name is at most 100 characters"
email: "that is too long to be an email address"
name:  "a name is between 2 and 100 characters"
```

Fixed by asking whether the **sentence** is plural-sensitive rather than
whether the options mention a count - which is what `%{count}` appearing in
it says. Ecto's own defaults still take the plural branch, because theirs do
contain it.

Why nothing caught it: `locale_test.exs`'s "every message the site ships is
translated" test reads the catalogues, and the catalogues were complete. The
defect lived entirely between a correct catalogue and the page. The new
test at `test/openresults_web/catalogue_test.exs` asks the changeset itself,
and fails on the old code.

### 2. Every score on the site uses the English decimal point · RECOMMENDED

`lib/openresults_web/controllers/tournament_html.ex:2097-2104`

```elixir
def number(value) when is_float(value) do
  if trunc(value) == value, do: Integer.to_string(trunc(value)), else: Float.to_string(value)
end
```

`Float.to_string/1` is locale-independent: it emits `5.5`, never `5,5`. This
one function formats every score, points total, tiebreak value and Keizer
value on the site - sixteen call sites in `tournament_html.ex`, plus
`meta.ex:119` (so it travels into the `og:description` a French reader
shares) and `player_history_html.ex:37`.

Both of this site's translated audiences write the decimal separator as a
comma. French chess federations print `5,5`; so does Dutch. A French
standings page currently shows `5.5` in every cell.

Not fixed, because it changes rendered output on every page. Two things that
make it cheaper than it looks, both checked rather than assumed:

- **The browser-side sort would not break.** The sort reads raw values off
  `data-points`, `data-value` and `data-rating` (`tournament_html.ex:368-400`)
  and `parseFloat`s those, never the rendered cell text. `number/1`'s output
  is display-only.
- **The page cache would not break.** Locale is already part of the cache
  key and of the ETag, so a Dutch page and an English page are already two
  entries; a comma in one of them changes nothing about that.

The judgement call is whether a results site should print the audience's
separator or the international one. FIDE-facing material writes `5.5`; the
hall writes `5,5`. Yours to decide.

### 3. Dates are ISO in every language, including on the hall screen · RECOMMENDED

`lib/openresults_web/controllers/tournament_html.ex:127-135`

```elixir
{start, finish} -> gettext("%{start} to %{finish}", start: start, finish: finish)
```

Only the connecting word is translated. `start` and `finish` are the ISO
strings the snapshot carried, passed through verbatim, so a French page
reads `2026-08-29 au 2026-09-01` and a French entry form reads
`début le 2026-08-29`. The same holds at the masthead
(`tournament_html.ex:60`), the front page (`index.html.heex:66-69`), the
player-history rows (`player_history_html.ex:27-29`), the `og:description`
(`meta.ex:187`), and - the most public surface this app has - the projector
view (`tournament_html.ex:1248`, `round.html.heex:15-17`).

Not fixed. ISO is defensible: it is unambiguous, it is what the payload
carries, and `player_history.ex:121-126` deliberately depends on ISO strings
sorting lexically ("`start_date` is an ISO date string, so lexical order is
chronological order"), so any change must stay on the display side only.
Recommended shape: format at the point of display from a parsed `Date`,
keyed off `assigns[:locale]`, leaving storage and sorting untouched.

### 4. French typography: no non-breaking space before `:` `;` `?` · FIXED

Fourteen French strings had a plain space before a colon, semicolon or
question mark, where French requires a non-breaking one. Without it a line
can break leaving the punctuation stranded at the start of the next line -
`Arbitre` / `: Dupont` - which is exactly the sort of thing that tells a
reader nobody who writes French has looked at the page.

All fourteen now carry U+00A0. The pass touched `msgstr` lines only, never
the header (where `plural=(n>1);` lives), and never a string containing an
escape sequence.

### 5. French said things the English deliberately did not · FIXED

Four wording corrections. Each is a case of the French being fluent and
saying something other than the English.

| Where | Was | Now | Why |
|---|---|---|---|
| Cross-table legend | `et le score de son propre point de vue` | `et le score du point de vue de ce joueur` | `son` attaches to `l'adversaire`, the last noun named, so the sentence said the score was from the **opponent's** side. The English says "from this player's own side" and the Dutch says `vanuit deze speler bekeken`; only the French had it backwards. This sentence is the key to reading a `6w1` cell, so getting the seat wrong is not cosmetic. |
| Player card footnote | `Le total officiel de l'arbitre` | `Le total de l'arbitre` | The English is "The arbiter's own total". "Officiel" is a claim this site avoids everywhere else - the footer says `Les résultats sont les siens, pas ceux de ce site` - and the French was making it. |
| Player history | `mentionne le FIDE %{id}` | `mentionne le numéro FIDE %{id}` | `le FIDE 1234567` is not French; the article needs a noun. Both plural forms corrected. |
| Entry form, rating hint | `Le classement sous lequel vous jouez` | `Le classement Elo sous lequel vous jouez` | The field's own label is `Elo`, and the `errors` catalogue already says `un classement Elo est un nombre entier`. Bare `classement` is this catalogue's word for **standings** (`Standings` → `Classement`), so the hint under the Elo box read as "the standings you play under". Three words for one field on one form, now two, and the ambiguous one is gone. |

### 6. The entry form's bye error cannot be translated at all · RECOMMENDED

`lib/openresults/registrations/entry.ex:203-205`

```elixir
defp bye_message(rounds) do
  "choose from the rounds this tournament has: #{Enum.join(rounds, ", ")}"
end
```

Built at runtime from the tournament's own round list, so there is a
different msgid per tournament and none of them can be in a catalogue. A
French visitor who trips it sees English. `errors.pot`'s own header comment
already documents this and argues it is unreachable from the rendered form,
"where the boxes only offer rounds that exist" - which is true of the form
and not of the endpoint. Reproduced here with a hand-built changeset:

```
requested_byes: "choose from the rounds this tournament has: 1, 2, 3"
```

A `curl` POST reaches it, and so does a form loaded before the arbiter
removed a round. Not fixed because it changes a message and needs a new
msgid in three catalogues. Recommended shape: make the sentence fixed and
the list a binding -
`gettext("choose from the rounds this tournament has: %{rounds}", rounds: Enum.join(rounds, ", "))` -
which is translatable, needs no plural, and keeps the list.

### 7. Two msgids for one column · RECOMMENDED

The player's rating column is gated on one display tick and labelled two
different ways in English:

- `gettext("Rating")` - standings (`tournament_html.ex:338`), starting rank
  (`:618`), entry form (`registration_html.ex:118`)
- `gettext("Elo")` - cross-table (`:877`), round pairings (`:1061`), player
  card (`:1166`, `:1559`)

So the English site says "Rating" on three surfaces and "Elo" on four for
the same number. French collapses both to `Elo`, which makes the French page
*more* consistent than the English one; Dutch carries the inconsistency
through as `Rating` / `Elo`.

This is a source-string defect, not a translation one, and fixing it changes
English UI text - so it is recommended rather than done. Consolidating on
one msgid would also retire a duplicate from all three catalogues.

### 8. The player card's placing is a fragment · RECOMMENDED

`lib/openresults_web/controllers/tournament_html.ex:1734-1741`

```heex
<span class="placing-rank">{@row["rank"]}</span>
<span class="placing-of">{gettext("of %{total}, on %{points}", ...)}</span>
```

The rank sits outside the string, so a translator gets `of %{total}, on
%{points}` and cannot move the number or put a word in front of it. The
same fact is a single whole msgid on the player-history page -
`rank %{rank} of %{total}, on %{points}` (`player_history_html.ex:34`) -
which renders in French as `place 3 sur 42, avec 5,5`. The card renders
`3` `sur 42, avec 5,5`: the same sentence, missing its first word, in the
one place a reader is most likely to be looking for their own result.

The msgid needed already exists, so this costs no new string. It is
recommended rather than fixed only because `placing-rank` is styled large
and deliberately separate, so merging the two spans is a design decision
about that page rather than a translation change.

### 9. `b` means Noirs in this cross-table and Blancs in a French one · RECOMMENDED

`lib/openresults_web/controllers/tournament_html.ex:1020-1021`

```elixir
defp colour_mark(:white), do: "w"
defp colour_mark(:black), do: "b"
```

The letters are deliberately untranslated, and the legend spells them out in
the reader's language, and the comment above them already anticipates the
problem. It is still worth recording that on the FFE's own grille
américaine the colour letters are **B for Blancs and N for Noirs**, so a
French reader arriving with that habit reads this site's `b` as the opposite
of what it means, on the one page where a single character carries the whole
fact. The legend is the mitigation and it is doing its job; nothing here is
wrong, and a French club's feedback on it would be worth more than another
round of reasoning. Listed so the next person does not have to rediscover
it.

### 10. Unwrapped English, in order of how likely anyone is to see it · RECOMMENDED

Everything below is outside the catalogues. None of it is a translation
defect; all of it is coverage.

- **The changelog page body** - `changelog_html/show.html.heex:9` renders
  the whole of `CHANGELOG.md` (about 12 KB of English prose) plus six
  English tag pills (`changelog.ex:29`, `~w(Feature Fix Change Removed
  Security Verified)`). The page's own chrome *is* translated. This is
  structurally hard rather than overlooked: `@html` is a compile-time module
  attribute, and `Gettext.put_locale/2` has not run when it is built. Moving
  it to a runtime function is the precondition for anything else here.
- **No-route 404s and 500s** - `error_html.ex:21-23` returns
  `Phoenix.Controller.status_message_from_template/1`, so `/anything-else`
  answers a bare `Not Found` in English. Verified: status 404, body
  `"Not Found"`, and **no `Vary` header at all**, because an unmatched path
  raises before any pipeline runs - which means the Locale plug never
  resolved a locale to translate into. Self-consistent, so a cache serving
  it to anyone is harmless; still English-only. Translating it needs its own
  locale resolution, which is a design decision, not an edit. Note that the
  404 a reader actually meets - a slug nobody published - does **not** go
  through this: it is `not_found.html.heex` and is fully translated
  (`locale_test.exs` asserts `Introuvable`).
- **The footer tooltip** - `build.ex:80,82` produce
  `"#{id()}, built #{built_at()}"` and `"#{id()} (not a release build)"`,
  rendered into `title={OpenResults.Build.long()}` on every page. Two
  English words, one hover away, everywhere.
- **No `<link rel="alternate" hreflang>` in `<head>`.** The only `hreflang`
  is on the visible picker anchors. `Locale.switch_path/2` already builds
  exactly the URLs those tags need, so this is a few lines and an SEO
  improvement rather than a reader-facing one.
- **Dead code carrying English.** `tournament.ex:568-573` (`officials/1`,
  hardcoded `"Deputy"` and `"Tempo"`) has no call sites anywhere in `lib`,
  `test` or any template - the masthead renders both facts through gettext
  instead. `core_components.ex:80` (`aria-label="close"`) and `:374`
  (`Actions`) sit in scaffold components (`flash/1`, `table/1`) that nothing
  calls. Worth deleting so they cannot be wired up later and reintroduce
  English.
- **Name sorting uses the reader's collation, not the page's.**
  `tournament_html.ex` sorts strings with
  `localeCompare(String(bv), undefined, {sensitivity: "base"})`. `undefined`
  means the browser's own locale. Passing
  `document.documentElement.lang` would sort a French page by French rules.
  Arguable either way - the reader's collation is also a defensible answer -
  so recorded rather than changed.
- **`?lang=` does not survive navigation inside an iframe.** The picker's
  links carry the parameter; no other link on the site does, and the cookie
  that would otherwise carry the choice forward is exactly what a browser
  blocks in a third-party frame. `Locale`'s moduledoc argues the parameter
  "survives an iframe", and it does - for the one page it is on. A reader
  who picks French inside a club's embed and then clicks through to round 2
  is back on `accept-language`. The same applies to the right-click player
  card, which fetches the player page without the parameter.

---

## Checked and clean

Stated explicitly so none of it is re-audited.

**The page cache varies on locale correctly.** This was the highest-severity
thing available to find and it is right, in all three places it has to be:

- `Revalidate.Page`'s key is `{slug, snapshot_id, locale, etag}`
  (`page.ex:139`), so one page in two languages is two entries.
- The ETag itself is `"#{id}-#{locale}-#{digest}"` (`revalidate.ex:243`), so
  a browser holding the Dutch page is answered 200 rather than 304 when it
  next asks in French.
- The response carries `Vary: accept-language, cookie, accept-encoding` -
  the Locale plug sets the first two and `Revalidate` merges the third onto
  them rather than overwriting.
- `Plugs.Locale` runs on the `:browser` pipeline ahead of `Revalidate`
  (`router.ex:28`), which is what makes the locale known before an ETag is
  built or the cache is consulted.
- A publish drops that tournament's entries in **every** language
  (`page.ex:126`, `match_delete` on `{slug, :_, :_, :_}`), so locale in the
  key does not leave a stale page behind in the language that was not
  republished.

It is also already tested, which is why no test was added for it:
`page_cache_test.exs:71` walks it end to end ("one reader's language is
never served to a reader who asked for another"), `:181-222` state it at the
unit level, and `revalidate_test.exs:89` covers the validator
("a validator from one language does not answer for another").

**Catalogue integrity.** All three locales carry exactly the 208 `default`
and 16 `errors` messages the templates do - no missing entries, no extras,
no duplicate msgids, no obsolete `#~` entries anywhere. Every `#:` source
reference points at a file that exists, at a line within it.

**Bindings.** Zero mismatches. Every `%{...}` in every `nl` and `fr`
`msgstr` matches its msgid's exactly, plural forms included. Nothing on this
site can log `missing Gettext bindings`, which on a cached page polled every
twenty seconds by a hall full of phones would have been a production log
full of them. Also checked: no stray `%` outside a `%{...}`, and no
`%[...]`-style placeholder (the sibling repo's trap) anywhere.

**Escaping.** Established which way each path goes before checking anything.
HEEx escapes every `{gettext(...)}` it renders, and exactly three msgids are
rendered **raw**, through `TournamentHTML.anchor/2` and `raw/1`
(`received.html.heex:7,17` and `player.html.heex:71`). No catalogue in any
locale contains `&`, `<`, `>`, or a pre-escaped entity (`&amp;`, `&nbsp;`,
`&#8594;` and friends) - so neither hazard is live: nothing renders a
literal `&amp;` to a reader, and nothing puts unescaped markup into the
three raw sentences. Both halves now have a test. The bindings interpolated
into those three all pass through `escaped/1` first, including `@name` from
the form - the one payload-adjacent value that enters a `raw/1` on this
site.

**Plural forms.** `nl` declares `nplurals=2; plural=(n != 1);` and `fr`
declares `nplurals=2; plural=(n>1);`, which is correct and is the case where
the two genuinely differ: at zero, Dutch takes the plural ("0 rondes") and
French the singular ("0 ronde"). This matters at runtime, not only in
Poedit - this version of gettext parses `Plural-Forms` out of the PO file
(`Gettext.Plural.plural_info/3`, `compiler.ex:563`) and pluralises from it.
All six plural messages have both forms filled in both locales.

**Opposite pairs.** Every pair and set that must not invert was enumerated
and checked in both languages. None is swapped:

- White / Black → `Wit` / `Zwart`, `Blancs` / `Noirs`
- half-point / full-point / zero-point / pairing-allocated bye → four
  distinct, correctly matched renderings in each language. This is the
  highest-risk set on the site (a full-point bye shown as half would
  misreport a score) and both are right.
- discarded / not counted / unplayed round, and their `%{count}` forms →
  distinct and correctly paired with their singulars
- Live now / Upcoming / Finished → `Nu bezig` / `Binnenkort` / `Afgelopen`,
  `En direct` / `À venir` / `Terminés`
- All clubs / All federations / All categories → parallel in both
- Entries closed / Entry sent / Too many entries / Too many waiting → four
  distinct outcome pages, distinct in both

Sort direction turned out not to be a string pair at all: the standings
convey it through `aria-sort="ascending"/"descending"`, which are ARIA
tokens the screen reader localises, correctly left in English. There are no
next/previous controls anywhere - pagination is `Page %{page} of %{count}`
and the projector cycles itself. `show how this was reached` is
visually-hidden text inside a `<summary>`, where the browser announces the
expanded state, so it needs no "hide" counterpart.

**Identical-to-source entries.** Separated from gaps rather than counted.
Every `nl` and `fr` msgstr byte-identical to its English msgid is a
legitimate loanword, abbreviation or code: `Elo`, `Bye`/`Byes`/`bye`,
`Score`, `Club`, `Points`/`Pts` (fr), `Rating` (nl - Dutch chess says
"rating"), `Nat`, `Cat`, `Tit`, `Bd` (nl, from `Bord`), `#`,
`FIDE %{id}`, `absent` (fr), `Arbiter: %{name}` and `Tempo: %{time_control}`
(nl - both words are Dutch), and `%{player} in %{tournament}.` (nl - the
sentence genuinely is identical). **No gaps.**

**Names and codes.** `OpenResults`, `OpenPairings`, `FIDE`, federation codes
(`BEL`, `NOR`), FIDE title codes (`GM`, `IM`, `WFM`, …), tiebreak
identifiers and the payload's own labels are untranslated everywhere, which
is correct. Nothing that must stay English got translated. `Ainalrami` does
not appear on this site at all.

**French chess vocabulary.** Read end to end and checked against how French
federations actually write, not from memory: `ronde`, `appariement`,
`départage`, `classement`, `échiquier`, `couleur`, `forfait`, `bye`,
`grille américaine` for the cross-table, `Homologué FIDE` for FIDE-rated,
`Arbitre adjoint` for the deputy, `Cadence` for the time control, `Points
Keizer`, `ronde non jouée`, `article 16 de la FIDE`. All of it is the right
register and the right term. `grille américaine` in particular is the exact
FFE word and not the calque a machine would produce. Aside from the items in
§4 and §5, this catalogue reads as though somebody who knows French chess
wrote it - which, given nobody has reviewed it, is a better result than the
brief expected.

**Dutch chess vocabulary.** Same pass. `ronde`, `paring`/`paringen`,
`kruistabel`, `stand`, `tiebreaks`, `bord`, `kleur`, `forfait`, `bye`,
`arbiter`, `Spelerskaart`, `Startnummer`, `Beamerweergave` for the projector
view - all correct and idiomatic. One register note, not a defect and not
changed: the Dutch follows the English's singular "they" for the arbiter
with plural `zij` + plural verb (`zij beslissen wie speelt`, `tot zij u
hebben ingeschreven`), in about six strings. Dutch has no singular *they*,
so this reads as several arbiters rather than as gender-neutral. Repeating
`de arbiter`, or `die`, would be the usual way out. It is consistent across
all six, which is why it is a style choice to make once rather than a bug.

**Locale resolution.** Order is `?lang=` → cookie → `accept-language` → `en`
(`locale.ex:126`). Region subtags collapse correctly: `fr-BE`, `fr-FR` → `fr`
and `nl-BE`, `nl-NL` → `nl`, by taking the part before the first hyphen
(`locale.ex:167`). Quality values order the header and a malformed one sorts
last rather than raising. All of this is already covered by
`locale_test.exs`, including the junk-header cases, so nothing was added.
`<html lang>` follows the resolved locale (`root.html.heex:2` →
`layouts.ex:61`), and so does `og:locale` (`nl_BE` / `fr_BE` / `en_GB`).

**The per-process `put_locale` trap has no shape here.** Worth writing down
because it is the one thing that does not transfer from the arbiter's app.
There, a LiveView's mount and its later renders are different callbacks in a
process the plug never touched. Here every page is a controller and a HEEx
template rendered inside the request process the Locale plug ran in, so the
locale is set for the whole render. Checked for the two ways it could still
go wrong and found neither: there is no `Task`, `spawn`, `Agent` or
`GenServer.call` anywhere on a render path, and no `gettext(...)` in a module
attribute or a default argument, which would freeze the compile-time locale
into the compiled module. The one compile-time string that does exist is
`Changelog.@html`, which is untranslated by design (§10).

**Fragments.** Four candidates examined; one worth reporting (§8). The
others are fine as they are: `", not published"` is appended to a round
label and its leading comma makes the ordering constraint explicit, and it
works in all three languages; the cross-table's two-sentence footnote is two
whole sentences rendered adjacently, not one sentence split; `Meta.with_where`
appends city and dates to an already-complete sentence with punctuation
glue only. Page titles interpolate translated pieces around a fixed `" - "`
in a fixed order (`tournament_controller.ex:95,137`), which a translator
cannot reorder - noted, not recommended, because the pieces are a tournament
name and a page name and no language wants them the other way round. No
recommendation anywhere in this document is to wrap more fragments.

**The anomaly in `en/default.po`.** `priv/gettext/en/LC_MESSAGES/default.po`
is byte-for-byte `priv/gettext/default.pot` - a different header block, plus
`Language: en` and `Plural-Forms` - with **zero** filled `msgstr`. All 208
are empty, which for a source-language catalogue is exactly right: the msgid
*is* the translation, and `locale_test.exs` exempts `en` from its
"everything is translated" check for that reason. So: correct, not
accidental, and hiding nothing.

The brief's count of ~77 filled entries does not reproduce; the file has
none. What is really in there, and is worth knowing, is **six `fuzzy` flags
that exist only in `en`**:

```
%{tournament} does not publish player cards.
%{tournament} does not publish round pairings.
%{tournament} does not publish standings.
All federations
Reset
Standings of %{tournament}, before round 1.
```

Those are the fossil record of six msgids that changed after the catalogues
existed: `mix gettext.extract --merge` fuzzy-matched each to an older
message in all three files, and whoever corrected `nl` and `fr` dropped the
flag there and left it in `en`, where an empty `msgstr` made it harmless.
`locale_test.exs`'s guard is deliberately built to ignore exactly this
combination (fuzzy **and** blank), and its own comment says so. All six
translations were checked against the current msgid: all six are correct.
Left in place - they are a true record of what happened, and clearing them
would only mean `mix gettext.merge` writing them again next time.

---

## What only a person can confirm

Set the browser to `fr-BE` (and separately `nl-BE`) and walk these. Nothing
above substitutes for it, and item 9 in particular needs a reader rather
than an auditor.

1. **A live tournament page.** Standings, several rounds, a player card.
   Read the tie-break footnotes as prose - they are the longest sentences on
   the site and the ones a machine translation would fail at.
2. **The cross-table.** Read the legend, then read a cell. Does `b` read as
   *Noirs* or does the FFE habit (`B` = Blancs) fight it? This is §9 and it
   is the one question an audit cannot answer.
3. **Scores.** Confirm whether `5.5` or `5,5` is what you want a Belgian
   spectator to see (§2), and whether `2026-08-29` or `29/08/2026` is what
   you want on the hall screen (§3). Both are decisions, not defects.
4. **The projector view** (`?display=1`) on a real screen. Check the page
   counter, the paused message, and that the round's date reads acceptably
   at that size.
5. **The registration form.** Submit it empty; submit it with a 200-character
   club name (that is finding §1 - it should now be French); submit a bad
   e-mail; tick a bye. Read every hint under every field.
6. **The four outcome pages** - sent, closed, queue full, too many. They
   carry the longest prose on the site and the least traffic, so nobody has
   read them in French.
7. **The language picker inside a club's iframe.** Pick French, then click
   through to another round. §10's last item predicts you land back in your
   browser's language; confirm whether that matters to you.
8. **The entry form's FIDE search.** The results list is payload text, but
   confirm the panel around it reads right.
9. **Ask one French-speaking club and one Flemish club to read a page.**
   Every finding in §5 is the kind of thing that is obvious to a native
   reader in ten seconds and takes an audit an hour. Six more of them
   probably exist.

---

## Tests added

`test/openresults_web/catalogue_test.exs` - 11 tests, one per class of
defect that turned out to be decidable rather than a judgement call:

- the three locales carry exactly the template's messages, each once, with
  nothing retired
- every `#:` reference points at a file and a line that exist
- no translation asks for a binding its caller does not pass, or drops one
  the sentence is about (singular and plural)
- the three raw-rendered sentences hold no `&`, `<` or `>` in any language
- no message anywhere carries a pre-escaped HTML entity
- each locale declares its own plural rule, and it is the right one
- every plural form is filled
- **every message the entry changeset can produce is answered in Dutch and
  French** - this is finding §1, and it fails on the old code
- the two changeset messages that interpolate a range constant still match
  the msgids they were copied into, so widening `@rating_range` or
  `@birth_years` breaks a test instead of silently shipping English

`test/openresults_web/locale_test.exs` - one added: a length failure on the
entry form is answered in French. Finding §1 through the real render path
rather than through the function.

No test was added for the locale cache key: it is already covered three
times over, as noted above.
