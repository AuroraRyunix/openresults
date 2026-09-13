defmodule OpenResultsWeb.Admin.SettingsController do
  @moduledoc """
  Server settings and the public notice.

  Each change is the panel's usual pair on one path, with the value carried
  to the confirmation page in the query string - nothing here is personal:

    * `GET /admin/settings/:key` - the form for one setting;
    * `GET /admin/settings/:key?value=...` - checked exactly as the boot
      checks the environment (`OpenResults.ServerSettings.validate/2`): the
      form again with a sentence, or the confirmation page;
    * `POST /admin/settings/:key` - the change, confirmed, checked again;
    * `GET`/`POST /admin/settings/:key/reset` - removes the panel's value.

  The notice follows the same shape at `/admin/settings/notice` (with
  `notice[...]` fields) and `/admin/settings/notice/clear`.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components, only: [render_not_found: 2, at: 1]

  alias OpenResults.Federations.BEL, as: BelFederation
  alias OpenResults.Moderation
  alias OpenResults.PublicNotice
  alias OpenResults.ServerSettings
  alias OpenResultsWeb.Admin.Confirmation

  plug Confirmation when action in [:setting, :reset, :notice, :clear_notice]

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Settings",
      settings: Moderation.server_settings(),
      locked: ServerSettings.locked(),
      notice: Moderation.public_notice(),
      now: DateTime.utc_now(),
      bel: BelFederation.admin_stats()
    )
  end

  # --- one setting -------------------------------------------------------------

  def confirm_setting(conn, %{"key" => name} = params) do
    with_key(conn, name, fn key ->
      case params["value"] do
        nil ->
          render_form(conn, key, nil, nil)

        raw ->
          case ServerSettings.validate(key, raw) do
            {:ok, value} -> render_setting_confirmation(conn, key, value)
            {:error, sentence} -> render_form(conn, key, text(raw), sentence)
          end
      end
    end)
  end

  def setting(conn, %{"key" => name} = params) do
    with_key(conn, name, fn key ->
      case Moderation.put_server_setting(key, params["value"], conn.assigns.admin) do
        {:ok, described} ->
          conn
          |> put_flash(
            :info,
            "#{ServerSettings.spec(key).label} is now #{shown(described.value)}, saved in the panel."
          )
          |> redirect(to: ~p"/admin/settings")

        {:error, {:invalid_value, sentence}} ->
          render_form(conn, key, text(params["value"]), sentence)
      end
    end)
  end

  defp render_form(conn, key, value, error) do
    conn
    |> put_status(if error, do: :unprocessable_entity, else: :ok)
    |> render(:setting,
      page_title: ServerSettings.spec(key).label,
      setting: ServerSettings.describe(key),
      spec: ServerSettings.spec(key),
      value: value,
      error: error
    )
  end

  defp render_setting_confirmation(conn, key, value) do
    described = ServerSettings.describe(key)
    spec = ServerSettings.spec(key)

    Confirmation.render_page(conn,
      title: "Change #{String.downcase(spec.label)}?",
      action: ~p"/admin/settings/#{key}",
      button: "Save #{shown(value)}",
      cancel: ~p"/admin/settings",
      danger: false,
      hidden: %{"value" => ServerSettings.encode(value)},
      consequences: [
        "Now: #{shown(described.value)} (#{source_text(described)}).",
        "After: #{shown(value)}, saved in the panel. It takes effect at once, on the next " <>
          "request, and wins over #{spec.variable} until it is reset to default.",
        spec.help
      ]
    )
  end

  # --- reset -------------------------------------------------------------------

  def confirm_reset(conn, %{"key" => name}) do
    with_key(conn, name, fn key ->
      described = ServerSettings.describe(key)

      if described.source == :panel do
        fallback = ServerSettings.fallback(key)
        spec = ServerSettings.spec(key)

        Confirmation.render_page(conn,
          title: "Reset #{String.downcase(spec.label)} to default?",
          action: ~p"/admin/settings/#{key}/reset",
          button: "Reset to default",
          cancel: ~p"/admin/settings",
          danger: false,
          consequences: [
            "The panel's value, #{shown(described.panel)}, is removed.",
            "In force afterwards: #{shown(fallback.value)} " <>
              "(#{source_text(Map.put(fallback, :variable, spec.variable))})."
          ]
        )
      else
        not_in_panel(conn, key)
      end
    end)
  end

  def reset(conn, %{"key" => name}) do
    with_key(conn, name, fn key ->
      case Moderation.reset_server_setting(key, conn.assigns.admin) do
        {:ok, described} ->
          conn
          |> put_flash(
            :info,
            "#{ServerSettings.spec(key).label} is reset: #{shown(described.value)} " <>
              "(#{source_text(described)})."
          )
          |> redirect(to: ~p"/admin/settings")

        {:error, :not_set} ->
          not_in_panel(conn, key)
      end
    end)
  end

  defp not_in_panel(conn, key) do
    conn
    |> put_flash(
      :error,
      "Nothing changed: #{ServerSettings.spec(key).label} has no value saved in the panel."
    )
    |> redirect(to: ~p"/admin/settings")
  end

  # --- the public notice -------------------------------------------------------

  def confirm_notice(conn, params) do
    case params["notice"] do
      nil ->
        render_notice_form(conn, stored_values(Moderation.public_notice()), %{})

      fields ->
        values = notice_values(fields)
        changeset = Moderation.change_public_notice(values)

        if changeset.valid? do
          render(conn, :notice_confirm,
            page_title: "Set the notice",
            notice: changeset_notice(changeset),
            hidden: hidden_notice(changeset),
            current: Moderation.public_notice()
          )
        else
          render_notice_form(conn, values, errors(changeset))
        end
    end
  end

  def notice(conn, params) do
    values = notice_values(params["notice"])

    case Moderation.set_public_notice(values, conn.assigns.admin) do
      {:ok, notice} ->
        conn
        |> put_flash(:info, notice_set_message(notice))
        |> redirect(to: ~p"/admin/settings")

      {:error, changeset} ->
        render_notice_form(conn, values, errors(changeset))
    end
  end

  def confirm_clear_notice(conn, _params) do
    case Moderation.public_notice() do
      nil ->
        no_notice(conn)

      notice ->
        Confirmation.render_page(conn,
          title: "Clear the notice?",
          action: ~p"/admin/settings/notice/clear",
          button: "Clear notice",
          cancel: ~p"/admin/settings",
          danger: false,
          consequences: [
            "Now: \"#{notice.en}\".",
            "It disappears from every public page at once."
          ]
        )
    end
  end

  def clear_notice(conn, _params) do
    case Moderation.clear_public_notice(conn.assigns.admin) do
      {:ok, _previous} ->
        conn
        |> put_flash(:info, "The notice is cleared.")
        |> redirect(to: ~p"/admin/settings")

      {:error, :not_set} ->
        no_notice(conn)
    end
  end

  defp no_notice(conn) do
    conn
    |> put_flash(:error, "Nothing changed: there is no notice.")
    |> redirect(to: ~p"/admin/settings")
  end

  defp render_notice_form(conn, values, errors) do
    conn
    |> put_status(if errors == %{}, do: :ok, else: :unprocessable_entity)
    |> render(:notice_form, page_title: "Set the notice", values: values, errors: errors)
  end

  defp notice_set_message(%{expires_at: nil}),
    do: "The notice is set, on every public page until it is cleared."

  defp notice_set_message(%{expires_at: at}),
    do: "The notice is set, on every public page until #{at(at)}."

  # The form's fields, as text or nil - a map or a list where text belongs is
  # read as nothing, never as a crash.
  defp notice_values(fields) when is_map(fields) do
    Map.new(["en", "nl", "fr", "level", "expires_at"], fn key ->
      value = if is_binary(fields[key]), do: fields[key], else: nil
      {key, if(key == "expires_at", do: instant_text(value), else: value)}
    end)
  end

  defp notice_values(_absent), do: notice_values(%{})

  # `<input type="datetime-local">` sends `2026-09-13T22:30`, which the panel
  # labels UTC; the confirmation carries the full instant.
  defp instant_text(nil), do: nil

  defp instant_text(text) do
    text = String.trim(text)

    if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/, text),
      do: text <> ":00Z",
      else: text
  end

  defp stored_values(nil), do: %{"level" => "info"}

  defp stored_values(notice) do
    %{
      "en" => notice.en,
      "nl" => notice.nl,
      "fr" => notice.fr,
      "level" => notice.level,
      "expires_at" => notice.expires_at && DateTime.to_iso8601(notice.expires_at)
    }
  end

  defp changeset_notice(changeset) do
    %{
      en: Ecto.Changeset.get_field(changeset, :en),
      nl: Ecto.Changeset.get_field(changeset, :nl),
      fr: Ecto.Changeset.get_field(changeset, :fr),
      level: Ecto.Changeset.get_field(changeset, :level),
      expires_at: Ecto.Changeset.get_field(changeset, :expires_at)
    }
  end

  defp hidden_notice(changeset) do
    notice = changeset_notice(changeset)

    %{
      "notice[en]" => notice.en,
      "notice[nl]" => notice.nl || "",
      "notice[fr]" => notice.fr || "",
      "notice[level]" => notice.level,
      "notice[expires_at]" =>
        if(notice.expires_at, do: DateTime.to_iso8601(notice.expires_at), else: "")
    }
  end

  defp errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.reverse()
    |> Map.new(fn {field, {message, _opts}} -> {field, sentence(field, message)} end)
  end

  defp sentence(:en, "is required"),
    do: "Write the notice in English; it is what every page falls back to."

  defp sentence(:level, _), do: "Choose information or warning."
  defp sentence(:expires_at, "must be in the future"), do: "The expiry must be in the future."

  defp sentence(:expires_at, _),
    do: "Give the expiry as a date and a time, in UTC, or leave it empty."

  defp sentence(_field, "should be at most" <> _),
    do: "Keep it to #{PublicNotice.max_length()} characters."

  defp sentence(_field, "is plain text"),
    do: "Plain text only: no HTML, so no < or >."

  defp sentence(_field, message), do: message

  # --- shared ------------------------------------------------------------------

  defp with_key(conn, name, fun) do
    case ServerSettings.key(name) do
      {:ok, key} -> fun.(key)
      :error -> render_not_found(conn, "There is no server setting called #{name}.")
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: nil

  @doc false
  def shown(nil), do: "none"
  def shown(value) when is_integer(value), do: OpenResultsWeb.Admin.Components.thousands(value)
  def shown(value) when is_binary(value), do: "\"#{value}\""

  @doc false
  def source_text(%{source: :panel}), do: "saved in the panel"
  def source_text(%{source: :environment, variable: variable}), do: "from #{variable}"
  def source_text(%{source: :default}), do: "the built-in default"
end
