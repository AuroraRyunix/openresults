defmodule OpenResultsWeb.Admin.ActionLogHTML do
  @moduledoc """
  The action log page. English only, not wrapped in gettext - see
  `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components

  def index(assigns) do
    ~H"""
    <h1>Action log</h1>

    <form method="get" action={~p"/admin/action-log"} class="admin-filters" id="action-log-filters">
      <label>
        Who
        <input
          type="search"
          name="actor"
          value={@filters["actor"]}
          placeholder="an email, break-glass or retention"
        />
      </label>
      <label>
        Action
        <select name="action">
          <option value="">Any</option>
          <option :for={name <- @action_names} value={name} selected={@filters["action"] == name}>
            {name}
          </option>
        </select>
      </label>
      <label>
        Target
        <select name="target_type">
          <option value="">Any</option>
          <option :for={type <- @target_types} value={type} selected={@filters["target_type"] == type}>
            {type}
          </option>
        </select>
      </label>
      <label>
        Target id
        <input
          type="search"
          name="target"
          value={@filters["target"]}
          placeholder="slug, in_... or number"
        />
      </label>
      <button type="submit">Filter</button>
    </form>

    <.actions_table actions={@actions} id="action-log" />

    <.pager path={~p"/admin/action-log"} params={@filters} page={@page} more?={@more?} />
    """
  end
end
