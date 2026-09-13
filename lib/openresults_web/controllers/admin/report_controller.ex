defmodule OpenResultsWeb.Admin.ReportController do
  @moduledoc """
  Reports from the public: the open and resolved queues, one report, and
  resolving it with a written resolution.

  Resolving changes nothing about the tournament. That is on purpose and the
  page says so: hiding or deleting is its own confirmed action, one click away
  from the report, so the log shows both what was decided and what was done.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components,
    only: [render_not_found: 2, page_window: 1, page_rows: 1]

  alias OpenResults.Moderation
  alias OpenResultsWeb.Admin.{Confirmation, Params}

  plug Confirmation when action in [:resolve]

  # `OpenResults.Moderation.resolve_report/3` keeps this much and cuts the
  # rest; the page says so instead of letting it happen quietly.
  @max_resolution 2000

  def index(conn, params) do
    {page, window} = page_window(params)
    status = Params.one_of(params["status"], ["open", "resolved"]) || "open"

    {reports, more?} =
      %{status: status}
      |> Map.merge(window)
      |> Moderation.list_reports()
      |> page_rows()

    render(conn, :index,
      page_title: "Reports",
      reports: reports,
      status: status,
      open_count: Moderation.counts().open_reports,
      page: page,
      more?: more?
    )
  end

  def show(conn, %{"id" => id}) do
    with_report(conn, id, fn report ->
      render(conn, :show,
        page_title: "Report #{report.id}",
        report: report,
        tournament: Moderation.get_tournament(report.tournament_slug)
      )
    end)
  end

  def confirm_resolve(conn, %{"id" => id}) do
    with_report(conn, id, fn report ->
      if report.status == "open" do
        render_resolve(conn, report, nil, nil)
      else
        conn
        |> put_flash(:error, "Report #{report.id} is already resolved.")
        |> redirect(to: ~p"/admin/reports/#{report.id}")
      end
    end)
  end

  def resolve(conn, %{"id" => id} = params) do
    with_report(conn, id, fn report ->
      resolution = Params.text(params["resolution"])

      cond do
        is_nil(resolution) ->
          render_resolve(
            conn,
            report,
            params["resolution"],
            "Write what was done, or why nothing was. Nothing was changed."
          )

        String.length(resolution) > @max_resolution ->
          render_resolve(
            conn,
            report,
            resolution,
            "Keep the resolution to #{@max_resolution} characters. Nothing was changed."
          )

        true ->
          case Moderation.resolve_report(report.id, resolution, conn.assigns.admin) do
            {:ok, resolved} ->
              conn
              |> put_flash(:info, "Resolved report #{resolved.id}.")
              |> redirect(to: ~p"/admin/reports")

            {:error, :already_resolved} ->
              conn
              |> put_flash(:error, "Nothing changed: report #{report.id} was already resolved.")
              |> redirect(to: ~p"/admin/reports/#{report.id}")

            {:error, :not_found} ->
              gone(conn, id)
          end
      end
    end)
  end

  defp render_resolve(conn, report, resolution, error) do
    conn
    |> put_status(if error, do: :unprocessable_entity, else: :ok)
    |> render(:resolve,
      page_title: "Resolve report #{report.id}",
      report: report,
      # Only text goes back into the field; `resolution[]=x` arrives as a list.
      resolution: if(is_binary(resolution), do: resolution),
      max_resolution: @max_resolution,
      error: error
    )
  end

  defp with_report(conn, id, fun) do
    case Moderation.get_report(id) do
      nil -> gone(conn, id)
      report -> fun.(report)
    end
  end

  defp gone(conn, id), do: render_not_found(conn, "No report has the id #{id}.")
end
