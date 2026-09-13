defmodule OpenResultsWeb.Admin.SwitchController do
  @moduledoc """
  The two runtime switches, flipped from the dashboard through a
  confirmation page.

  The confirmation posts the value it offered (`value=true`), never "toggle".
  Two admins confirming the same flip at once then agree on the result
  instead of undoing each other.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components, only: [render_not_found: 2]

  alias OpenResults.Moderation
  alias OpenResults.PublicPublishing
  alias OpenResultsWeb.Admin.Confirmation

  plug Confirmation when action in [:update]

  @switches %{
    "registration_open" => :registration_open,
    "public_publishing_paused" => :public_publishing_paused
  }

  def confirm(conn, %{"key" => key}) do
    case Map.fetch(@switches, key) do
      {:ok, switch} ->
        current = Map.fetch!(Moderation.settings(), switch)
        render_confirmation(conn, key, switch, current, not current, [])

      :error ->
        render_not_found(conn, "There is no switch called #{key}.")
    end
  end

  def update(conn, %{"key" => key} = params) do
    case Map.fetch(@switches, key) do
      {:ok, switch} ->
        current = Map.fetch!(Moderation.settings(), switch)

        with value when value in ["true", "false"] <- params["value"],
             {:ok, _settings} <-
               Moderation.put_setting(switch, value == "true", conn.assigns.admin) do
          conn
          |> put_flash(:info, done(switch, value == "true"))
          |> redirect(to: ~p"/admin")
        else
          _unusable ->
            render_confirmation(conn, key, switch, current, not current,
              status: :unprocessable_entity,
              error: "That was not a value this switch takes. Nothing was changed; confirm again."
            )
        end

      :error ->
        render_not_found(conn, "There is no switch called #{key}.")
    end
  end

  defp render_confirmation(conn, key, switch, current, target, opts) do
    {title, button, danger, consequences} = wording(switch, target)

    Confirmation.render_page(
      conn,
      [
        title: title,
        action: ~p"/admin/switches/#{key}",
        button: button,
        cancel: ~p"/admin",
        danger: danger,
        hidden: %{"value" => to_string(target)},
        consequences: [now(switch, current) | consequences] ++ gate_note()
      ] ++ opts
    )
  end

  defp now(:registration_open, true), do: "Registration is open now."
  defp now(:registration_open, false), do: "Registration is closed now."
  defp now(:public_publishing_paused, true), do: "Public publishing is paused now."
  defp now(:public_publishing_paused, false), do: "Public publishing is active now."

  defp wording(:registration_open, true) do
    {"Open registration?", "Open registration", false,
     [
       "Any OpenPairings desktop copy that asks will be given an installation key, as long as " <>
         "its address is not blocked and the registration budgets allow it " <>
         "(#{PublicPublishing.registrations_per_address()} per address and " <>
         "#{PublicPublishing.registrations_per_day()} in all, per 24 hours).",
       "Tournaments those installations publish start pending: reachable at their address, " <>
         "but not on the front page, in search or on players' history pages until you approve them."
     ]}
  end

  defp wording(:registration_open, false) do
    {"Close registration?", "Close registration", false,
     [
       "New installations are refused: OpenPairings tells the arbiter the results site is not " <>
         "accepting new installations right now.",
       "Installations that already hold a key are not affected and keep publishing."
     ]}
  end

  defp wording(:public_publishing_paused, true) do
    {"Pause public publishing?", "Pause publishing", true,
     [
       "This takes arbiters' live updates offline mid-event. Every tournament published from " <>
         "OpenPairings with an installation key stops updating at once: results entered in the " <>
         "hall no longer reach this site until you resume.",
       "Their pages stay up, frozen at the last publish. Arbiters see an amber warning that the " <>
         "results site has paused publishing, and their updates wait on their machines. No new " <>
         "tournament can be created either.",
       "Not affected: tournaments published with the operator token (hosted OpenPairings), and " <>
         "deleting a tournament, which always works."
     ]}
  end

  defp wording(:public_publishing_paused, false) do
    {"Resume public publishing?", "Resume publishing", false,
     [
       "Installations can publish and create tournaments again. Updates waiting on arbiters' " <>
         "machines are sent on their next retry."
     ]}
  end

  # The switches are stored and flipped whatever the environment gate says,
  # and say nothing until it is on. Better said here than discovered later.
  defp gate_note do
    if PublicPublishing.enabled?() do
      []
    else
      [
        "Public publishing is switched off on this server (OPENRESULTS_PUBLIC_PUBLISHING is " <>
          "not enabled), so this is stored but changes nothing until it is switched on."
      ]
    end
  end

  defp done(:registration_open, true), do: "Registration is open."
  defp done(:registration_open, false), do: "Registration is closed."
  defp done(:public_publishing_paused, true), do: "Public publishing is paused."
  defp done(:public_publishing_paused, false), do: "Public publishing has resumed."
end
