defmodule OpenResultsWeb.EventController do
  @moduledoc """
  `GET /e/:id` - one event: the tournaments that are sections of it, each as
  a card with what a visitor chooses between them by.

  `:id` is the random id the arbiter's app gave the group
  (`tournament.group.id` in each member's snapshot), not anything of this
  server's. Which tournaments appear is decided by
  `OpenResultsWeb.EventGroup.members/1` and, under it,
  `OpenResults.TournamentGroups`: public here, claiming this id themselves,
  one publisher. An id nobody claims, an id with one tournament left, and an
  id whose tournaments are all hidden are the same 404 - this page never
  says an event exists that it cannot show.

  Not behind `Revalidate`: there is no single tournament to key a tag on.
  Rendered per request from the members' current snapshots, which are
  already in memory for their own pages.
  """

  use OpenResultsWeb, :controller

  alias OpenResultsWeb.EventGroup
  alias OpenResultsWeb.Meta

  def show(conn, %{"id" => id}) do
    case EventGroup.members(id) do
      {name, members} ->
        render(conn, :show,
          page_title: name,
          page_description: Meta.index(),
          name: name,
          members: members
        )

      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: OpenResultsWeb.TournamentHTML)
        |> render(:not_found,
          page_title: gettext("Not found"),
          page_description: Meta.not_found(),
          message: gettext("There is no event at this address."),
          back: ~p"/"
        )
    end
  end
end
