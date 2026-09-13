defmodule OpenResults.ServerSettingsTest do
  @moduledoc """
  Server settings editable at runtime (the admin upgrade, 2026-09-13):
  precedence panel > environment > default, the boot's validation applied to
  the panel, the ETS cache, the action log, and the hot paths that read them.
  """
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.PublicPublishing
  alias OpenResults.RateLimit
  alias OpenResults.Repo
  alias OpenResults.ServerSettings
  alias OpenResults.ServerSettings.Setting

  @admin %{email: "settings-admin@example.org"}

  setup do
    RateLimit.reset()
    :ok
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:openresults, key)
    Application.put_env(:openresults, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:openresults, key, v)
        :error -> Application.delete_env(:openresults, key)
      end
    end)
  end

  defp delete_env(key) do
    previous = Application.fetch_env(:openresults, key)
    Application.delete_env(:openresults, key)
    on_exit(fn -> with {:ok, v} <- previous, do: Application.put_env(:openresults, key, v) end)
  end

  describe "precedence" do
    test "default, then environment, then panel; reset goes back one step" do
      delete_env(:installation_max_tournaments)

      assert %{value: 50, source: :default} =
               ServerSettings.describe(:installation_max_tournaments)

      assert PublicPublishing.installation_max_tournaments() == 50

      put_env(:installation_max_tournaments, 12)

      assert %{value: 12, source: :environment, environment: 12} =
               ServerSettings.describe(:installation_max_tournaments)

      {:ok, described} = Moderation.put_server_setting(:installation_max_tournaments, "7", @admin)
      assert %{value: 7, source: :panel, environment: 12, default: 50} = described
      assert PublicPublishing.installation_max_tournaments() == 7

      {:ok, reset} = Moderation.reset_server_setting(:installation_max_tournaments, @admin)
      assert %{value: 12, source: :environment} = reset
      assert PublicPublishing.installation_max_tournaments() == 12

      assert {:error, :not_set} =
               Moderation.reset_server_setting(:installation_max_tournaments, @admin)
    end

    test "every setting reports a source, and the texts too" do
      put_env(:operator_name, "From Env")
      delete_env(:terms_url)

      for described <- Moderation.server_settings() do
        assert described.source in [:panel, :environment, :default]
      end

      assert %{value: "From Env", source: :environment} = ServerSettings.describe(:operator_name)
      assert %{value: nil, source: :default} = ServerSettings.describe(:terms_url)

      {:ok, _} = Moderation.put_server_setting("terms_url", "https://example.org/t", @admin)

      assert %{value: "https://example.org/t", source: :panel} =
               ServerSettings.describe(:terms_url)
    end

    test "GET /api/server reflects the operator name and terms link saved in the panel" do
      put_env(:operator_name, "Env Operator")
      put_env(:terms_url, "https://env.example/terms")

      {:ok, _} = Moderation.put_server_setting(:operator_name, "  Panel Operator ", @admin)
      {:ok, _} = Moderation.put_server_setting(:terms_url, "https://panel.example/terms", @admin)

      body = build_conn() |> get("/api/server") |> json_response(200)
      assert body["operator"] == "Panel Operator"
      assert body["terms_url"] == "https://panel.example/terms"

      {:ok, _} = Moderation.reset_server_setting(:operator_name, @admin)

      assert build_conn() |> get("/api/server") |> json_response(200) |> Map.get("operator") ==
               "Env Operator"
    end
  end

  describe "validation" do
    # {key, refused, accepted} - the SAME table is run against the boot below.
    @cases [
      {:operator_name, [String.duplicate("x", 101), "two\nlines"], ["ZeroTwo", " Club  "]},
      {:terms_url,
       [
         "http://example.org/terms",
         "example.org/terms",
         "https://",
         "https://a b.org/",
         "ftp://example.org"
       ], ["https://example.org/terms"]},
      {:contact_email,
       [
         "operator",
         "operator@example",
         "two words@example.org",
         "a@b@example.org",
         "<script>@example.org",
         "op\"erator@example.org",
         "operator@example.org?subject=x",
         String.duplicate("x", 250) <> "@example.org"
       ], ["operator@example.org", "  takedown@zerotwo.cloud  "]},
      {:installation_max_versions, ["0", "-1", "1.5", "abc", ""], ["1", "100"]},
      {:min_free_disk_percent, ["-1", "101", "ten", ""], ["0", "10", "100"]},
      {:registrations_per_address, ["-1", "x", ""], ["0", "10"]},
      {:registrations_per_day, ["-5", "2e3", ""], ["0", "200"]},
      {:installation_publishes_per_minute, ["0", "-1", ""], ["1", "30"]},
      {:installation_max_tournaments, ["-1", "fifty", ""], ["0", "50"]},
      {:installation_max_snapshot_bytes, ["0", "8000001", "3MiB", ""],
       ["1", "8000000", "3145728"]}
    ]

    test "the panel refuses with a sentence, stores nothing and logs nothing" do
      for {key, refused, accepted} <- @cases do
        for raw <- refused do
          before = length(Moderation.list_actions(%{limit: 10_000}))

          assert {:error, {:invalid_value, sentence}} =
                   Moderation.put_server_setting(key, raw, @admin),
                 "#{key} accepted #{inspect(raw)}"

          assert is_binary(sentence) and sentence =~ ~r/\.$/
          assert Repo.get(Setting, Atom.to_string(key)) == nil
          assert length(Moderation.list_actions(%{limit: 10_000})) == before
        end

        for raw <- accepted do
          assert {:ok, _} = Moderation.put_server_setting(key, raw, @admin),
                 "#{key} refused #{inspect(raw)}"
        end
      end
    end

    test "a map or a list where text belongs is refused, never a crash" do
      for key <- ServerSettings.keys(), raw <- [%{"a" => 1}, ["1"], nil] do
        assert {:error, {:invalid_value, _}} = Moderation.put_server_setting(key, raw, @admin)
      end
    end

    test "an unknown key is refused without making an atom" do
      assert {:error, :unknown_setting} =
               Moderation.put_server_setting("ingest_token", "x", @admin)

      assert {:error, :unknown_setting} =
               Moderation.put_server_setting(:public_publishing, "enabled", @admin)

      assert {:error, :unknown_setting} = Moderation.reset_server_setting("nope", @admin)
    end

    test "is exactly the boot's: config/runtime.exs refuses what the panel refuses" do
      variables = Map.new(ServerSettings.keys(), &{&1, ServerSettings.spec(&1).variable})

      for {key, refused, accepted} <- @cases do
        variable = Map.fetch!(variables, key)

        # Not blank: an empty variable is unset on some platforms (Windows
        # among them), so it cannot be told apart from no variable here.
        for raw <- refused, raw != "" do
          assert_raise RuntimeError, ~r/#{variable}/, fn -> boot_with(variable, raw) end
        end

        for raw <- accepted do
          config = boot_with(variable, raw)
          {:ok, value} = ServerSettings.validate(key, raw)

          stored = config[:openresults][key]

          assert stored == value or (is_binary(stored) and String.trim(stored) == value),
                 "#{variable}=#{inspect(raw)} booted as #{inspect(stored)}, the panel " <>
                   "reads #{inspect(value)}"
        end
      end
    end
  end

  defp boot_with(variable, value) do
    previous = System.get_env(variable)
    System.put_env(variable, value)

    try do
      Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :test)
    after
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end
  end

  describe "the action log" do
    test "records old and new, and the source the old one came from" do
      put_env(:registrations_per_day, 150)

      {:ok, _} = Moderation.put_server_setting(:registrations_per_day, "90", @admin)

      assert %Action{
               actor: "settings-admin@example.org",
               action: "put_server_setting",
               target_type: "setting",
               target: "registrations_per_day",
               details: %{"from" => 150, "from_source" => "environment", "to" => 90}
             } = hd(Moderation.list_actions(%{limit: 1}))

      {:ok, _} = Moderation.reset_server_setting(:registrations_per_day, @admin)

      assert %Action{
               action: "reset_server_setting",
               details: %{"from" => 90, "to" => 150, "to_source" => "environment"}
             } = hd(Moderation.list_actions(%{limit: 1}))
    end
  end

  describe "the contact email" do
    test "is none by default, saves, resets, and each change is logged" do
      delete_env(:contact_email)

      assert %{value: nil, source: :default, variable: "OPENRESULTS_CONTACT_EMAIL"} =
               ServerSettings.describe(:contact_email)

      {:ok, described} =
        Moderation.put_server_setting(:contact_email, " takedown@example.org ", @admin)

      assert %{value: "takedown@example.org", source: :panel} = described

      assert %Action{
               actor: "settings-admin@example.org",
               action: "put_server_setting",
               target_type: "setting",
               target: "contact_email",
               details: %{
                 "from" => nil,
                 "from_source" => "default",
                 "to" => "takedown@example.org"
               }
             } = hd(Moderation.list_actions(%{limit: 1}))

      {:ok, reset} = Moderation.reset_server_setting(:contact_email, @admin)
      assert %{value: nil, source: :default} = reset

      assert %Action{
               action: "reset_server_setting",
               target: "contact_email",
               details: %{"from" => "takedown@example.org", "to" => nil, "to_source" => "default"}
             } = hd(Moderation.list_actions(%{limit: 1}))
    end
  end

  describe "the cache" do
    test "a saved value is read from ETS, not the database" do
      {:ok, _} = Moderation.put_server_setting(:installation_max_versions, "5", @admin)

      # Behind the cache's back: the row goes, the cached value stays.
      Repo.delete_all(Setting)
      assert ServerSettings.get(:installation_max_versions) == 5

      # Until the cache is emptied, when the next read loads what is there.
      ServerSettings.clear_cache()
      assert ServerSettings.get(:installation_max_versions) == 20
    end

    test "a reader filling a miss never overwrites a writer's refresh" do
      {:ok, _} = Moderation.put_server_setting(:installation_max_versions, "5", @admin)
      # A late reader holding what it read before the write.
      :ets.insert_new(OpenResults.ServerSettings, {:panel, %{installation_max_versions: 99}})
      assert ServerSettings.get(:installation_max_versions) == 5
    end
  end

  describe "the hot paths read the panel's value" do
    test "the snapshot size cap" do
      {installation, key} = installation!()
      slug = mint!(installation)

      {:ok, _} = Moderation.put_server_setting(:installation_max_snapshot_bytes, "1000", @admin)

      conn = slug |> payload() |> publish(key, random_key())
      assert %{"error" => "snapshot_too_large", "limit_bytes" => 1000} = json_response(conn, 413)
    end

    test "the publish budget" do
      {installation, key} = installation!()
      {:ok, _} = Moderation.put_server_setting(:installation_publishes_per_minute, "2", @admin)

      assert mint(key).status == 201
      assert mint(key).status == 201
      assert %{"error" => "rate_limited"} = mint(key) |> json_response(429)
      assert installation.trusted == false
    end

    test "the tournament limit" do
      {_installation, key} = installation!()
      {:ok, _} = Moderation.put_server_setting(:installation_max_tournaments, "1", @admin)

      assert mint(key).status == 201
      assert %{"error" => "tournament_limit", "limit" => 1} = mint(key) |> json_response(403)
    end
  end
end
