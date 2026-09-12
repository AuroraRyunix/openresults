defmodule OpenResultsWeb.ReportControllerTest do
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.RateLimit
  alias OpenResults.Reports
  alias OpenResults.Reports.Report
  alias OpenResultsWeb.CoreComponents

  setup do
    RateLimit.reset()
    slug = unique_slug("report")
    slug |> payload() |> publish(operator_token()) |> json_response(200)
    {:ok, slug: slug}
  end

  defp visitor(address), do: build_conn() |> put_req_header("cf-connecting-ip", address)

  defp doc(conn, status), do: LazyHTML.from_document(html_response(conn, status))

  defp report(attrs \\ %{}) do
    Map.merge(
      %{
        "reason" => "personal_data",
        "details" => "My email address is in the club column of player 4.",
        "contact_email" => "reporter@example.invalid"
      },
      attrs
    )
  end

  describe "GET /t/:slug/report" do
    test "offers the four reasons, details and an optional email, with no cookie", %{slug: slug} do
      conn = get(build_conn(), "/t/#{slug}/report")
      document = doc(conn, 200)

      assert document
             |> LazyHTML.query(~s(input[type="radio"][name="report[reason]"]))
             |> LazyHTML.attribute("value") == Report.reasons()

      assert document |> LazyHTML.query(~s(textarea[name="report[details]"])) |> Enum.count() == 1

      assert document |> LazyHTML.query(~s(input[name="report[contact_email]"])) |> Enum.count() ==
               1

      assert get_resp_header(conn, "set-cookie") == []
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      # A form, so the refresher must leave it alone - the layout looks for
      # this id.
      assert document |> LazyHTML.query("form#report-form") |> Enum.count() == 1
    end
  end

  describe "POST /t/:slug/report" do
    test "stores the report with the client address, and says so", %{slug: slug} do
      conn = post(visitor("198.51.100.44"), "/t/#{slug}/report", report: report())

      assert html_response(conn, 200) =~ "Report sent"

      assert [
               %Report{
                 tournament_slug: ^slug,
                 reason: "personal_data",
                 details: "My email address is in the club column of player 4.",
                 contact_email: "reporter@example.invalid",
                 client_address: "198.51.100.44",
                 status: "open"
               }
             ] = Reports.list(slug: slug)
    end

    test "the email and the details are optional", %{slug: slug} do
      conn =
        post(build_conn(), "/t/#{slug}/report",
          report: %{"reason" => "other", "details" => " ", "contact_email" => ""}
        )

      assert html_response(conn, 200)
      assert [%Report{details: nil, contact_email: nil}] = Reports.list(slug: slug)
    end

    test "refuses a missing or unknown reason, long details and a bad email, keeping the answers",
         %{slug: slug} do
      for attrs <- [
            %{"reason" => nil},
            %{"reason" => "because"},
            %{"details" => String.duplicate("x", 2001)},
            %{"contact_email" => "not-an-address"}
          ] do
        conn = post(build_conn(), "/t/#{slug}/report", report: report(attrs))
        document = doc(conn, 422)

        assert document |> LazyHTML.query(".field .wrong") |> Enum.count() == 1, inspect(attrs)
        RateLimit.reset()
      end

      assert Reports.list(slug: slug) == []
    end

    test "a server-side field cannot be set from the form", %{slug: slug} do
      post(build_conn(), "/t/#{slug}/report",
        report:
          report(%{
            "status" => "resolved",
            "tournament_slug" => "someone-else",
            "client_address" => "1.2.3.4"
          })
      )

      assert [%Report{status: "open", tournament_slug: ^slug, client_address: "127.0.0.1"}] =
               Reports.list(slug: slug)
    end

    test "is rate-limited by client address like the entry form", %{slug: slug} do
      for _ <- 1..5 do
        assert html_response(
                 post(visitor("203.0.113.8"), "/t/#{slug}/report", report: report()),
                 200
               )
      end

      conn = post(visitor("203.0.113.8"), "/t/#{slug}/report", report: report())
      assert html_response(conn, 429) =~ "Too many reports"
      assert [_seconds] = get_resp_header(conn, "retry-after")
      assert length(Reports.list(slug: slug)) == 5

      # Somebody else, somewhere else, is not held up.
      assert html_response(
               post(visitor("203.0.113.9"), "/t/#{slug}/report", report: report()),
               200
             )

      # And an entry is its own allowance.
      assert html_response(
               post(visitor("203.0.113.8"), "/t/#{slug}/register",
                 registration: %{"name" => "De Vos, Ilse", "email" => "ilse@example.invalid"}
               ),
               200
             )
    end

    test "404s for a slug nobody published" do
      assert html_response(post(build_conn(), "/t/nobody-2026/report", report: report()), 404)
      assert html_response(get(build_conn(), "/t/nobody-2026/report"), 404)
      assert Reports.list(slug: "nobody-2026") == []
    end
  end

  describe "in Dutch and French" do
    test "the form, the reasons and the confirmation are translated", %{slug: slug} do
      for {lang, heading, reason, sent} <- [
            {"nl", "Deze pagina melden", "De uitslagen kloppen niet of zijn verzonnen",
             "Melding verstuurd"},
            {"fr", "Signaler cette page", "Les résultats sont faux ou inventés",
             "Signalement envoyé"}
          ] do
        html = html_response(get(build_conn(), "/t/#{slug}/report?lang=#{lang}"), 200)
        assert html =~ heading
        assert html =~ reason

        RateLimit.reset()

        sent_html =
          build_conn()
          |> put_req_header("accept-language", lang)
          |> post("/t/#{slug}/report", report: report())
          |> html_response(200)

        assert sent_html =~ sent
      end
    end

    test "every message the report changeset can produce is answered in Dutch and French" do
      changeset =
        Report.submission_changeset(%{
          "reason" => "because",
          "details" => String.duplicate("x", 2001),
          "contact_email" => String.duplicate("a", 300) <> "@b.c"
        })

      missing = Report.submission_changeset(%{})
      bad_format = Report.submission_changeset(%{"reason" => "other", "contact_email" => "nope"})

      errors = changeset.errors ++ missing.errors ++ bad_format.errors
      assert length(errors) >= 5

      for locale <- ~w(nl fr) do
        Gettext.put_locale(OpenResultsWeb.Gettext, locale)

        for {field, {msgid, _opts} = error} <- errors do
          refute CoreComponents.translate_error(error) == msgid,
                 "#{locale}: the report form answers #{field} in English - #{inspect(msgid)}"
        end
      end
    after
      Gettext.put_locale(OpenResultsWeb.Gettext, "en")
    end
  end
end
