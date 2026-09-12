defmodule OpenResultsWeb.ChangelogHTML do
  @moduledoc """
  The markup for `OpenResultsWeb.ChangelogController`.

  Thin on purpose, like every other `*_html` module here: the one fact this
  page adds beyond what `OpenResults.Changelog` already rendered is the
  page's own heading, and everything else is `{raw/1}` of that pre-rendered
  HTML.
  """

  use OpenResultsWeb, :html

  embed_templates "changelog_html/*"
end
