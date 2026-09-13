defmodule OpenResultsWeb.Admin.ActionLogController do
  @moduledoc """
  The action log: every moderation change, every break-glass use and every
  retention run, newest first, filtered and paged.

  Read-only. The log is append-only in the database and nothing in the panel
  offers to change it.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components, only: [page_window: 1, page_rows: 1]

  alias OpenResults.Moderation
  alias OpenResultsWeb.Admin.Params

  # The spellings `OpenResults.Moderation` writes - the contract's
  # "Action log rows" list. A filter for anything else would only ever find
  # nothing, so it is not offered.
  @actions ~w(put_setting approve hide unhide delete transfer transfer_all suspend unsuspend
              revoke resolve_report block_address unblock break_glass_publish break_glass_delete
              break_glass_read retention)
  @target_types ~w(setting tournament installation report address_block)

  def index(conn, params) do
    {page, window} = page_window(params)

    filters = %{
      "actor" => Params.text(params["actor"]),
      "action" => Params.one_of(params["action"], @actions),
      "target_type" => Params.one_of(params["target_type"], @target_types),
      "target" => Params.text(params["target"])
    }

    {actions, more?} =
      filters
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(window)
      |> Moderation.list_actions()
      |> page_rows()

    render(conn, :index,
      page_title: "Action log",
      actions: actions,
      filters: filters,
      action_names: @actions,
      target_types: @target_types,
      page: page,
      more?: more?
    )
  end
end
