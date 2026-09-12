defmodule OpenResultsWeb.MintController do
  @moduledoc """
  `POST /api/tournaments` - mints a slug bound to the installation asking.

  Reached only through `OpenResultsWeb.Plugs.IngestAuth`, which has already
  refused a suspended, revoked, blocked, paused or over-budget installation
  (`OpenResultsWeb.InstallationAccess`, action `:mint`).

  The operator token is refused here with `installation_key_required`. It is
  not unauthorised - it may do everything else - but a minted slug is bound to
  an installation and the operator is not one. The operator publishes to
  whatever slug it likes, exactly as before.

  The body is `{}` and nothing in it is read. In particular there is no way to
  ask for a name: see `OpenResults.Tournaments`, "Minting", for why the whole
  slug is the server's choice.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Tournaments
  alias OpenResultsWeb.ApiError

  def create(conn, _params) do
    case conn.assigns.credential do
      {:installation, installation} ->
        case Tournaments.mint(installation) do
          {:ok, tournament} ->
            conn |> put_status(:created) |> json(%{slug: tournament.slug})

          {:error, {:tournament_limit, limit}} ->
            ApiError.send(conn, :tournament_limit, %{limit: limit})
        end

      :operator ->
        ApiError.send(conn, :installation_key_required)
    end
  end
end
