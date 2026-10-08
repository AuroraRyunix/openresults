defmodule OpenResultsWeb.Admin.RelayKeyController do
  @moduledoc """
  A tournament's relay keys: the list, making one, revoking one. See
  `OpenResults.RelayKeys` for what a key may do (one route, one tournament).

  Making a key is the usual pair - GET the confirmation, POST to do it - with
  one difference: the POST does not redirect. The key exists in this response
  and nowhere else, so the response IS the page that shows it, once. Reload it
  and the browser asks to resubmit the form, which makes a second key, not a
  second look at the first; the list afterwards shows only a label and the
  last four characters.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components, only: [render_not_found: 2]

  alias OpenResults.Moderation
  alias OpenResults.RelayKeys
  alias OpenResultsWeb.Admin.{Confirmation, Params}
  alias OpenResultsWeb.Admin.TournamentController

  plug Confirmation when action in [:create, :revoke]

  def index(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, fn tournament ->
      render(conn, :index,
        page_title: "Relay keys for #{TournamentController.label(tournament)}",
        tournament: tournament,
        keys: RelayKeys.list(slug),
        active: RelayKeys.active_count(slug),
        max_active: RelayKeys.max_active()
      )
    end)
  end

  def confirm_create(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, &render_new(conn, &1, nil, nil))
  end

  def create(conn, %{"slug" => slug} = params) do
    with_tournament(conn, slug, fn tournament ->
      label = Params.text(params["label"])

      case Moderation.create_relay_key(slug, label, conn.assigns.admin) do
        {:ok, %{relay_key: relay_key, key: key}} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> render(:created,
            page_title: "Relay key made",
            tournament: tournament,
            relay_key: relay_key,
            key: key
          )

        {:error, :too_many} ->
          render_new(
            conn,
            tournament,
            label,
            "#{TournamentController.label(tournament)} already has " <>
              "#{RelayKeys.max_active()} relay keys in use. Revoke one first."
          )

        {:error, :not_found} ->
          gone(conn, slug)
      end
    end)
  end

  def confirm_revoke(conn, %{"slug" => slug, "id" => id}) do
    with_tournament(conn, slug, fn tournament ->
      case RelayKeys.get(slug, id) do
        %{revoked_at: nil} = relay_key ->
          Confirmation.render_page(conn,
            title: "Revoke this relay key?",
            action: ~p"/admin/tournaments/#{slug}/relay-keys/#{relay_key.id}/revoke",
            button: "Revoke relay key",
            cancel: ~p"/admin/tournaments/#{slug}/relay-keys",
            consequences: [
              "#{describe(relay_key)} of #{TournamentController.label(tournament)}.",
              "The box holding it is refused from the next request on. Its games already " <>
                "stored stay. A revoked key cannot be restored; make a new one.",
              "The tournament's other keys, the tournament key and the installation are untouched."
            ]
          )

        %{} ->
          conn
          |> put_flash(:error, "That relay key is already revoked.")
          |> redirect(to: ~p"/admin/tournaments/#{slug}/relay-keys")

        nil ->
          render_not_found(conn, "No such relay key for #{slug}.")
      end
    end)
  end

  def revoke(conn, %{"slug" => slug, "id" => id}) do
    with_tournament(conn, slug, fn _tournament ->
      case Moderation.revoke_relay_key(slug, id, conn.assigns.admin) do
        {:ok, relay_key} ->
          conn
          |> put_flash(:info, "Revoked: #{describe(relay_key)} no longer works.")
          |> redirect(to: ~p"/admin/tournaments/#{slug}/relay-keys")

        {:error, :already_revoked} ->
          conn
          |> put_flash(:error, "Nothing changed: that relay key was already revoked.")
          |> redirect(to: ~p"/admin/tournaments/#{slug}/relay-keys")

        {:error, :not_found} ->
          render_not_found(conn, "No such relay key for #{slug}.")
      end
    end)
  end

  defp render_new(conn, tournament, label, error) do
    conn
    |> put_status(if error, do: :unprocessable_entity, else: :ok)
    |> render(:new,
      page_title: "New relay key for #{TournamentController.label(tournament)}",
      tournament: tournament,
      label: label,
      error: error
    )
  end

  @doc false
  def describe(%{label: label, hint: hint}) when is_binary(label),
    do: "The relay key \"#{label}\" (ends #{hint})"

  def describe(%{hint: hint}), do: "The relay key ending #{hint}"

  defp with_tournament(conn, slug, fun) do
    case Moderation.get_tournament(slug) do
      nil -> gone(conn, slug)
      tournament -> fun.(tournament)
    end
  end

  defp gone(conn, slug) do
    render_not_found(conn, "No tournament has the slug #{slug}. It may have been deleted.")
  end
end
