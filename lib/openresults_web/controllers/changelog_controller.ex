defmodule OpenResultsWeb.ChangelogController do
  @moduledoc """
  `GET /changelog` - what has changed on this site, release by release.

  The footer's build stamp (`OpenResults.Build.id/0`) is a link here on
  every page, the same way OpenPairings makes its own version number a link
  to its own `/changelog` - see that app's router for the reasoning this
  one shares: describing the application rather than any one tournament, it
  needs no account and holds nothing to protect.

  ## Why this is not on `OpenResultsWeb.Plugs.Revalidate`

  That plug answers "has THIS TOURNAMENT changed since you last asked" by
  looking up a slug's latest snapshot id - see its own moduledoc. This page
  is not about a tournament and has no slug, which is exactly the shape
  `OpenResultsWeb.PlayerHistoryController` and the front page's `index/2`
  already are, and neither of them sits behind that plug either. Nothing
  here reads the database at all: `OpenResults.Changelog` renders
  `CHANGELOG.md` at COMPILE time, so what this page shows can only change on
  a deploy, never between two requests against the same running build.
  """

  use OpenResultsWeb, :controller

  alias OpenResultsWeb.Meta

  def show(conn, _params) do
    render(conn, :show,
      page_title: gettext("Changelog"),
      page_description: Meta.changelog(),
      changelog_html: OpenResults.Changelog.html()
    )
  end
end
