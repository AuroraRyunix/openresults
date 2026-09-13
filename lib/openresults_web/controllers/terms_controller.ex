defmodule OpenResultsWeb.TermsController do
  @moduledoc """
  `GET /terms` - the site's terms, acceptable use and privacy, in one page.

  Two readers. The arbiter whose OpenPairings asks, once, whether to publish
  here: its consent dialog links `terms_url` from `GET /api/server`, and with
  none set that is this page (`OpenResultsWeb.ServerController`). And the
  player who finds their name somewhere they did not want it, who needs to
  learn in a minute how to have it removed.

  ## Accurate to the code

  Every statement on the page is about what this application does, and the
  numbers are read from the running configuration rather than written into
  the copy: the retention periods from `OpenResults.Retention` and
  `OpenResults.Backup` (see `docs/privacy-retention.md`), the operator's name
  and contact address from `OpenResults.ServerSettings`. A change of
  behaviour that makes a sentence here untrue is a change to this page too.

  ## Not cached

  Not behind `OpenResultsWeb.Plugs.Revalidate`, so no ETag and no page cache:
  the page depends on server settings that change in the admin panel, and a
  cached copy keyed only on locale would go on showing an old contact address.
  It reads three ETS-cached settings and some application config, which is
  cheaper than a cache lookup would save.

  ## The date

  `@updated` is the "last updated" date, and the one edit a change to the
  wording needs besides the wording.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Backup
  alias OpenResults.Retention
  alias OpenResults.ServerSettings
  alias OpenResultsWeb.Meta

  # Change this whenever the page's wording changes in substance.
  @updated ~D[2026-09-13]

  @doc "The date the terms were last changed."
  @spec updated() :: Date.t()
  def updated, do: @updated

  def show(conn, _params) do
    render(conn, :show,
      page_title: gettext("Terms and privacy"),
      page_description: Meta.terms(),
      updated: Date.to_iso8601(@updated),
      operator: ServerSettings.get(:operator_name),
      contact_email: ServerSettings.get(:contact_email),
      days: %{
        registrations: Retention.registration_retention_days(),
        report_contact: Retention.report_contact_retention_days(),
        addresses: Retention.days(),
        blocks: Retention.block_address_retention_days(),
        backups: Backup.retention()
      }
    )
  end
end
