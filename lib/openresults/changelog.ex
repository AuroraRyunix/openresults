defmodule OpenResults.Changelog do
  @moduledoc """
  Renders `CHANGELOG.md` (repo root) to HTML once, at compile time - mirrors
  `PairingsEngine.Changelog` in OpenPairings, which explains the two
  decisions worth repeating here rather than re-deriving:

  Read via `@external_resource`, not `:code.priv_dir/1` - `priv/` is the one
  directory guaranteed to ship with an OTP release, but `CHANGELOG.md` at
  the repo root is not, so there is no reliable *runtime* path back to it
  once a release has moved things around. `@external_resource` bakes the
  file's content into the compiled module at build time instead, which
  means editing `CHANGELOG.md` needs a rebuild to show up - same as every
  other code change in a compiled release, and exactly the property this
  page's own build stamp already assumes: the footer's version and this
  page's content change together, on a deploy, never independently.

  And the tag pills: the markdown writes `[Fix]` etc. as plain text so the
  file still reads on GitHub, and it is substituted for a coloured pill
  AFTER rendering rather than written as a `<span>` into the markdown -
  `OpenResults.Markdown` escapes text and emits only tags on its own
  allowlist, so a literal `<span>` in the source would come out as visible
  characters rather than markup. Doing the substitution here keeps that
  property: the only markup this step can introduce is the six known tags.
  """

  @changelog_path Path.expand("../../CHANGELOG.md", __DIR__)
  @external_resource @changelog_path

  @tags ~w(Feature Fix Change Removed Security Verified)

  @html (case File.read(@changelog_path) do
           {:ok, markdown} ->
             Enum.reduce(@tags, OpenResults.Markdown.to_html(markdown), fn tag, acc ->
               String.replace(
                 acc,
                 "[#{tag}]",
                 ~s(<span class="cl-tag cl-#{String.downcase(tag)}">#{tag}</span>)
               )
             end)

           {:error, _reason} ->
             "<p>CHANGELOG.md was not found at compile time.</p>"
         end)

  @doc "CHANGELOG.md, pre-rendered to HTML at compile time."
  def html, do: @html
end
