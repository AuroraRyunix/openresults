defmodule OpenResultsWeb.AdminSettingsTest do
  @moduledoc """
  The admin panel's settings page, the public notice's form and the trusted
  installation controls - each change through its confirmation page and a
  CSRF-checked POST, and input that cannot be used sent back with a sentence.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.ServerSettings
  alias OpenResults.Tournaments
  alias OpenResultsWeb.AdminWorld

  @admin "arbiter@example.org"

  setup do
    reset_admin_access()
    configure_access()
    {:ok, world: AdminWorld.build()}
  end

  # A confirmation reached with a query string posts to the bare path.
  defp check_then_post(path, query, params) do
    page = admin_get(path <> "?" <> URI.encode_query(query))
    token = page |> html_response(200) |> csrf_token()

    page
    |> next_request()
    |> dispatch(
      @endpoint,
      :post,
      path,
      Map.merge(%{"_csrf_token" => token, "confirm" => path}, params)
    )
  end

  defp doc(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  describe "the settings page" do
    test "shows every setting, where its value comes from, and the locked variables without secrets" do
      put = fn key, value ->
        previous = Application.fetch_env(:openresults, key)
        Application.put_env(:openresults, key, value)

        on_exit(fn ->
          with {:ok, v} <- previous, do: Application.put_env(:openresults, key, v)
        end)
      end

      put.(:backup_passphrase, "correct horse battery staple")
      put.(:registrations_per_day, 123)
      {:ok, _} = Moderation.put_server_setting(:operator_name, "Panel Op", %{email: @admin})

      html = admin_get("/admin/settings") |> html_response(200)
      document = LazyHTML.from_document(html)

      for key <- ServerSettings.keys() do
        assert document |> LazyHTML.query("#setting-#{key}") |> Enum.count() == 1, "#{key}"
      end

      assert document |> LazyHTML.query("#setting-operator_name") |> LazyHTML.text() =~ "panel"

      assert document |> LazyHTML.query("#setting-registrations_per_day") |> LazyHTML.text() =~
               "environment"

      assert document |> LazyHTML.query("#setting-terms_url") |> LazyHTML.text() =~ "default"

      locked = document |> LazyHTML.query("#locked-settings-table") |> LazyHTML.text()

      for variable <- ~w(OPENRESULTS_PUBLIC_PUBLISHING OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN
                         OPENRESULTS_ADMIN_ACCESS_AUD OPENRESULTS_ADMIN_EMAILS
                         OPENRESULTS_INGEST_TOKEN OPENRESULTS_BACKUP_PASSPHRASE BACKUP_RETENTION
                         DATABASE_PATH SECRET_KEY_BASE) do
        assert locked =~ variable
      end

      refute html =~ "test-ingest-token"
      refute html =~ "correct horse battery staple"
      refute html =~ OpenResultsWeb.AdminAccessHelpers.audience()

      # Nothing on the page offers to change a locked variable.
      refute html =~ ~s(href="/admin/settings/ingest_token")

      assert admin_get("/admin/settings/ingest_token") |> html_response(404) =~
               "no server setting"

      assert admin_get("/admin/settings/public_publishing") |> html_response(404)
    end
  end

  describe "changing a setting" do
    test "check, confirm, and it is in force and logged with old and new" do
      conn =
        check_then_post("/admin/settings/installation_max_versions", %{"value" => "7"}, %{
          "value" => "7"
        })

      assert redirected_to(conn) == "/admin/settings"
      assert ServerSettings.get(:installation_max_versions) == 7

      assert %Action{
               actor: @admin,
               action: "put_server_setting",
               target: "installation_max_versions",
               details: %{"to" => 7}
             } = last_action()
    end

    test "input the boot would refuse comes back to the form with its sentence, never a 500" do
      before = length(Moderation.list_actions(%{limit: 10_000}))

      for {key, raw} <- [
            {"min_free_disk_percent", "101"},
            {"terms_url", "http://example.org"},
            {"installation_publishes_per_minute", "0"},
            {"operator_name", "  "}
          ] do
        conn = admin_get("/admin/settings/#{key}?" <> URI.encode_query(%{"value" => raw}))
        html = html_response(conn, 422)
        assert html =~ ~s(id="setting-error"), key
      end

      # And a confirmed POST carrying a value the page never offered.
      page = admin_get("/admin/settings/min_free_disk_percent?value=5")
      token = page |> html_response(200) |> csrf_token()

      for value <- ["500", %{"x" => "1"}] do
        conn =
          page
          |> next_request()
          |> dispatch(@endpoint, :post, "/admin/settings/min_free_disk_percent", %{
            "_csrf_token" => token,
            "confirm" => "/admin/settings/min_free_disk_percent",
            "value" => value
          })

        assert html_response(conn, 422) =~ "whole number from 0 to 100"
      end

      assert length(Moderation.list_actions(%{limit: 10_000})) == before
    end

    test "the contact email: checked as an email address, confirmed, saved, logged and reset" do
      conn = admin_get("/admin/settings/contact_email?" <> URI.encode_query(%{"value" => "nope"}))
      assert html_response(conn, 422) =~ "one email address"
      assert ServerSettings.get(:contact_email) == nil

      conn =
        check_then_post("/admin/settings/contact_email", %{"value" => "takedown@example.org"}, %{
          "value" => "takedown@example.org"
        })

      assert redirected_to(conn) == "/admin/settings"
      assert ServerSettings.get(:contact_email) == "takedown@example.org"

      assert %Action{
               actor: @admin,
               action: "put_server_setting",
               target: "contact_email",
               details: %{"to" => "takedown@example.org"}
             } = last_action()

      conn = confirm_and_post("/admin/settings/contact_email/reset")
      assert redirected_to(conn) == "/admin/settings"
      assert ServerSettings.get(:contact_email) == nil

      assert %Action{actor: @admin, action: "reset_server_setting", target: "contact_email"} =
               last_action()
    end

    test "reset to default removes the panel's value" do
      {:ok, _} = Moderation.put_server_setting(:registrations_per_address, "3", %{email: @admin})

      conn = confirm_and_post("/admin/settings/registrations_per_address/reset")
      assert redirected_to(conn) == "/admin/settings"
      assert ServerSettings.describe(:registrations_per_address).source != :panel
      assert %Action{actor: @admin, action: "reset_server_setting"} = last_action()

      # With nothing to reset, the page says so rather than offering a button.
      conn = admin_get("/admin/settings/registrations_per_address/reset")
      assert redirected_to(conn) == "/admin/settings"
    end
  end

  describe "the public notice" do
    test "preview, confirm, set; then clear" do
      query = %{
        "notice[en]" => "Maintenance tonight",
        "notice[fr]" => "Maintenance ce soir",
        "notice[level]" => "warning",
        "notice[expires_at]" => "2099-01-01T22:30"
      }

      page = admin_get("/admin/settings/notice?" <> URI.encode_query(query))
      preview = doc(page)
      assert preview |> LazyHTML.query("#notice-preview-fr") |> LazyHTML.text() =~ "ce soir"
      # Dutch has no text of its own, so its visitors get the English.
      assert preview |> LazyHTML.query("#notice-preview-nl") |> LazyHTML.text() =~ "tonight"

      token = page |> html_response(200) |> csrf_token()

      hidden =
        preview
        |> LazyHTML.query(~s(#confirmation-form input[type="hidden"]))
        |> Enum.map(fn input ->
          {input |> LazyHTML.attribute("name") |> hd(),
           input |> LazyHTML.attribute("value") |> hd()}
        end)
        |> Enum.reject(fn {name, _} -> name in ["_csrf_token"] end)
        |> Map.new()

      assert hidden["notice[expires_at]"] == "2099-01-01T22:30:00Z"

      conn =
        page
        |> next_request()
        |> dispatch(
          @endpoint,
          :post,
          "/admin/settings/notice",
          Plug.Conn.Query.decode(URI.encode_query(Map.put(hidden, "_csrf_token", token)))
        )

      assert redirected_to(conn) == "/admin/settings"

      assert %{en: "Maintenance tonight", fr: "Maintenance ce soir", level: "warning"} =
               Moderation.public_notice()

      assert %Action{actor: @admin, action: "set_notice"} = last_action()

      conn = confirm_and_post("/admin/settings/notice/clear")
      assert redirected_to(conn) == "/admin/settings"
      assert Moderation.public_notice() == nil
      assert %Action{actor: @admin, action: "clear_notice"} = last_action()
    end

    test "a notice the form cannot take comes back with a sentence, never a 500" do
      for query <- [
            %{"notice[en]" => "", "notice[level]" => "info"},
            %{"notice[en]" => "<b>bold</b>", "notice[level]" => "info"},
            %{"notice[en]" => String.duplicate("x", 301), "notice[level]" => "info"},
            %{
              "notice[en]" => "ok",
              "notice[level]" => "info",
              "notice[expires_at]" => "2000-01-01T00:00"
            },
            %{"notice[en]" => "ok", "notice[level]" => "loud"},
            %{"notice[en][x]" => "ok"}
          ] do
        conn = admin_get("/admin/settings/notice?" <> URI.encode_query(query))
        assert html_response(conn, 422) =~ ~s(id="notice-form-errors"), inspect(query)
      end

      assert Moderation.public_notice() == nil
    end

    test "clearing when there is no notice says so" do
      assert redirected_to(admin_get("/admin/settings/notice/clear")) == "/admin/settings"
    end
  end

  describe "trusted installations" do
    test "trust, listing its pending tournaments from the checkbox; then stop trusting", %{
      world: world
    } do
      html = admin_get("/admin/installations/#{world.active.id}/trust") |> html_response(200)
      assert html =~ ~s(name="list_pending")

      conn =
        confirm_and_post("/admin/installations/#{world.active.id}/trust", %{
          "list_pending" => "true"
        })

      assert redirected_to(conn) == "/admin/installations/#{world.active.id}"
      assert Moderation.get_installation(world.active.id).trusted
      assert Tournaments.status(world.pending) == :listed
      assert %Action{actor: @admin, action: "trust"} = last_action()

      show = admin_get("/admin/installations/#{world.active.id}") |> doc()
      assert show |> LazyHTML.query("#installation-trusted") |> LazyHTML.text() =~ "Yes"

      conn = confirm_and_post("/admin/installations/#{world.active.id}/untrust")
      assert redirected_to(conn) == "/admin/installations/#{world.active.id}"
      refute Moderation.get_installation(world.active.id).trusted
      assert %Action{actor: @admin, action: "untrust"} = last_action()
    end

    test "without the checkbox its pending tournaments stay pending", %{world: world} do
      confirm_and_post("/admin/installations/#{world.active.id}/trust")
      assert Tournaments.status(world.pending) == :pending
    end

    test "a revoked installation is not offered trust", %{world: world} do
      conn = admin_get("/admin/installations/#{world.revoked.id}/trust")
      assert redirected_to(conn) == "/admin/installations/#{world.revoked.id}"
    end

    test "its own limits: check, confirm, save; out of range comes back to the form", %{
      world: world
    } do
      path = "/admin/installations/#{world.active.id}/limits"

      conn = admin_get(path <> "?check=1&limits[max_versions]=0&limits[max_tournaments]=abc")
      html = html_response(conn, 422)
      assert html =~ ~s(id="limit-max_versions-error")
      assert html =~ ~s(id="limit-max_tournaments-error")

      conn =
        check_then_post(
          path,
          %{"check" => "1", "limits[max_versions]" => "5", "limits[max_tournaments]" => ""},
          %{"limits" => %{"max_versions" => "5", "max_tournaments" => ""}}
        )

      assert redirected_to(conn) == "/admin/installations/#{world.active.id}"
      installation = Moderation.get_installation(world.active.id)
      assert installation.max_versions == 5
      assert installation.max_tournaments == nil
      assert %Action{actor: @admin, action: "set_installation_limits"} = last_action()
    end
  end

  describe "pending, as the panel words it" do
    test "a pending tournament says it is not on player pages yet, and offers to put it there", %{
      world: world
    } do
      html = admin_get("/admin/tournaments/#{world.pending}") |> html_response(200)
      assert html =~ "not on player pages yet"
      assert html =~ "Show on player pages"
    end
  end
end
