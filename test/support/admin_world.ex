defmodule OpenResultsWeb.AdminWorld do
  @moduledoc """
  A server with something on it, for the admin panel's page and action tests:
  installations in every status, tournaments in every status (one never
  published), open and resolved reports, a live address block and a log.

  Slugs are fresh on every call, for the reason
  `OpenResults.PublicPublishingFixtures` gives: the status and page caches
  are node-wide.
  """

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Installations
  alias OpenResults.Moderation
  alias OpenResults.Reports
  alias OpenResults.Snapshots

  @moderator %{email: "earlier-moderator@example.invalid"}

  def build do
    # Registered from inside the range the world blocks, so the block's
    # confirmation page has somebody to count.
    {active, _key} = installation!({203, 0, 113, 9})
    {suspended, _key} = installation!({198, 51, 100, 30})
    {revoked, _key} = installation!({198, 51, 100, 31})

    pending = published_by(active)
    hidden = published_by(active)
    unpublished = mint!(active)
    # What a request through the API would have recorded.
    :ok = Installations.touch(active, {203, 0, 113, 9})

    listed = unique_slug("brugge")

    {:ok, _} =
      Snapshots.ingest(put_in(payload(listed), ["tournament", "name"], "Brugge Rapid 2026"))

    {:ok, _} = Moderation.hide(hidden, @moderator)
    {:ok, _} = Moderation.suspend(suspended.id, @moderator)
    {:ok, _} = Moderation.revoke(revoked.id, @moderator, hide_tournaments: false)

    {:ok, open_report} =
      Reports.create(
        pending,
        %{
          "reason" => "personal_data",
          "details" => "My email address is on the standings page.",
          "contact_email" => "player@example.org"
        },
        {192, 0, 2, 50}
      )

    {:ok, resolved_report} = Reports.create(listed, %{"reason" => "other"}, nil)
    {:ok, resolved_report} = Moderation.resolve_report(resolved_report.id, "Fine", @moderator)

    {:ok, block} =
      Moderation.block_address(
        "192.0.2.0/24",
        DateTime.add(DateTime.utc_now(), 3 * 86_400, :second),
        "Registration flood",
        @moderator
      )

    %{
      active: active,
      suspended: suspended,
      revoked: revoked,
      pending: pending,
      listed: listed,
      hidden: hidden,
      unpublished: unpublished,
      open_report: open_report,
      resolved_report: resolved_report,
      block: block
    }
  end

  defp published_by(installation) do
    slug = mint!(installation)
    {:ok, _} = Snapshots.ingest(payload(slug), installation: installation, key: random_key())
    slug
  end
end
