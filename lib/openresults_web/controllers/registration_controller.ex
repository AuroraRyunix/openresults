defmodule OpenResultsWeb.RegistrationController do
  @moduledoc """
  The public entry form.

  The only place a member of the public can write to this server, and what it
  writes to is a QUEUE. Nothing here touches a tournament. The arbiter's
  machine pulls the queue and the arbiter decides who plays, exactly as with a
  paper entry form left on a table at the club - which is why every word on
  these two pages is careful never to say "you are entered".

  A tournament has to have published here before anybody can enter it. That is
  not a convenience check: a registration for `gent-spring-opne-2026` would
  otherwise sit in a queue no arbiter will ever pull, and this app is not
  allowed to invent a tournament from an entry. The 404 is the same one the
  standings page gives, for the same reason.

  Both actions run on the read pipeline, so like every other page on this site
  they set no cookie. See the router for why a form here needs neither a
  session nor a CSRF token, and what protects it instead.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.RateLimit
  alias OpenResults.Registrations
  alias OpenResults.Registrations.Entry
  alias OpenResults.Snapshots
  alias OpenResults.TournamentKeys
  alias OpenResultsWeb.Tournament

  # Five entries per ten minutes from one address. Chosen to be invisible to
  # the case that actually happens - a parent entering three children from one
  # phone - while making a script's thousandth POST cost ten minutes instead
  # of a millisecond.
  #
  # A honeypot field was considered and rejected: it catches a naive bot, but
  # it fails SILENTLY, and a password manager or an over-eager autofill
  # filling the hidden box would throw away a real person's only attempt with
  # no error. This form is one shot. It must never lose an entry quietly.
  @rate_limit 5
  @rate_window_ms :timer.minutes(10)

  @doc """
  `GET /t/:slug/register` - the entry form for a tournament that exists here.
  """
  def new(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, fn payload ->
      render_form(conn, slug, payload, Entry.new())
    end)
  end

  @doc """
  `POST /t/:slug/register` - validates one entry and puts it in the queue.

  Renders the confirmation directly rather than redirecting to it. The usual
  post/redirect/get exists to stop a refresh re-posting, and it needs somewhere
  to keep "you just submitted" between the two requests - a flash, and behind
  it a session and a cookie on a site that has none. The trade is a browser
  warning on refresh against a cookie on every reader, and a duplicate entry
  is the one mistake this system is already built to absorb: `Registrations`
  deduplicates nothing on purpose, because two entries for the same player is
  an arbiter's decision and always was.
  """
  def create(conn, %{"slug" => slug} = params) do
    # Before the database is touched, so a flood costs a lookup in ETS rather
    # than a query per request.
    case RateLimit.take({:registration, conn.remote_ip},
           limit: @rate_limit,
           window_ms: @rate_window_ms
         ) do
      :ok -> store(conn, slug, submitted(params))
      {:denied, retry_in_ms} -> too_many(conn, slug, retry_in_ms)
    end
  end

  defp store(conn, slug, attrs) do
    with_tournament(conn, slug, fn payload ->
      rounds = Tournament.round_slots(payload)

      case attrs |> Entry.changeset(rounds) |> Ecto.Changeset.apply_action(:insert) do
        {:ok, entry} ->
          received_at = DateTime.utc_now()

          case Registrations.ingest(Entry.to_payload(entry, slug, received_at),
                 received_at: received_at
               ) do
            {:ok, _registration} ->
              render(conn, :received,
                page_title: "Entry sent - #{Tournament.name(payload)}",
                payload: payload,
                slug: slug,
                # The name only. The email is the one thing this server holds
                # that a snapshot never carries, and a confirmation page is
                # still a rendered page.
                name: entry.name
              )

            {:error, _unstorable} ->
              # Unreachable in practice - the payload was built from the
              # contract two lines ago - but a person who has just typed their
              # details deserves a page that says what happened rather than a
              # stack trace.
              conn
              |> put_status(:internal_server_error)
              |> render_form(slug, payload, Entry.changeset(attrs, rounds),
                alarm:
                  "Something went wrong at our end and your entry was not stored. " <>
                    "Your answers are still below - please send it again."
              )
          end

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render_form(slug, payload, changeset)
      end
    end)
  end

  # The form's own params, or nothing. A caller who posts `?registration=x`
  # gets an empty form back rather than a 500, which is the same restraint
  # `OpenResults.Envelope` shows about payloads of the wrong shape.
  defp submitted(params) do
    case Map.get(params, "registration") do
      attrs when is_map(attrs) -> attrs
      _absent_or_wrong_shape -> %{}
    end
  end

  defp render_form(conn, slug, payload, changeset, opts \\ []) do
    render(conn, :new,
      page_title: "Enter #{Tournament.name(payload)}",
      payload: payload,
      slug: slug,
      rounds: Tournament.round_slots(payload),
      alarm: Keyword.get(opts, :alarm),
      form: Phoenix.Component.to_form(changeset, as: :registration)
    )
  end

  defp with_tournament(conn, slug, render_fun) do
    case Snapshots.latest(slug) do
      nil ->
        not_found(
          conn,
          "No tournament has published under #{slug}, so there is nothing to enter.",
          back: ~p"/"
        )

      snapshot ->
        if Tournament.registration_open?(snapshot.payload) do
          render_fun.(snapshot.payload)
        else
          closed(conn, slug)
        end
    end
  end

  # The arbiter has shut the door. A 404 would be wrong - the tournament is
  # right there on this site, and telling a player it does not exist sends
  # them to look for a link they already have. This says what happened and
  # points them at the tournament they were trying to enter.
  #
  # `403` rather than `200`, so a crawler or a script does not record a
  # closed form as a working one.
  defp closed(conn, slug) do
    conn
    |> put_status(:forbidden)
    |> render(:closed, page_title: "Entries are closed", back: ~p"/t/#{slug}")
  end

  defp too_many(conn, slug, retry_in_ms) do
    conn
    |> put_status(:too_many_requests)
    |> put_resp_header("retry-after", Integer.to_string(ceil(retry_in_ms / 1000)))
    |> render(:too_many,
      page_title: "Too many entries",
      minutes: max(1, ceil(retry_in_ms / 60_000)),
      back: ~p"/t/#{slug}"
    )
  end

  # One not-found page for the whole site, so a mistyped slug looks the same
  # whichever page it was mistyped on.
  defp not_found(conn, message, back: back) do
    conn
    |> put_status(:not_found)
    |> put_view(html: OpenResultsWeb.TournamentHTML)
    |> render(:not_found, page_title: "Not found", message: message, back: back)
  end

  @doc """
  The arbiter's pull: every entry this server holds for `slug`.

  Token-gated, and sitting alongside `/history` rather than beside the open
  read routes, because this is the ONE thing in the system that carries an
  email address. Everything a spectator can reach was chosen for publication
  by an arbiter; this was typed by a member of the public who expected the
  organiser to read it, and nobody else.

  The shape is a 1:1 render of the stored row rather than a bare array of
  payloads: the arbiter's machine has to tell one entry from another across
  repeated pulls so a discarded entry does not come back every time, and `id`
  is the only stable handle for that. A bare array would leave the client
  hashing the document to invent one.

  This server still never decides anything. It has no notion of an entry
  being "handled" - that is a fact about the arbiter's machine, and it is
  kept there. So this returns everything, every time, and is safe to call
  repeatedly.
  """
  def index(conn, %{"slug" => slug}) do
    case TournamentKeys.authorize_read(slug, tournament_key(conn)) do
      :ok -> render_index(conn, slug)
      {:error, reason} -> forbid(conn, reason)
    end
  end

  defp tournament_key(conn) do
    case Plug.Conn.get_req_header(conn, "x-openresults-key") do
      [key | _rest] -> key
      [] -> nil
    end
  end

  # 403 rather than 401, the same split the publish path makes: 401 means "you
  # may not talk to this server", 403 means "you may, but not to this
  # tournament". By here the caller has already proved it holds the ingest
  # token.
  defp forbid(conn, reason) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: Atom.to_string(reason), detail: forbid_detail(reason)})
  end

  defp forbid_detail(:key_required),
    do: "this tournament is claimed; send its key in x-openresults-key"

  defp forbid_detail(:key_mismatch),
    do: "the tournament key does not match the one this tournament was claimed with"

  defp render_index(conn, slug) do
    registrations = Registrations.list_for_tournament(slug)

    json(conn, %{
      "schema" => "openresults/registration-list",
      "version" => 1,
      "tournament_slug" => slug,
      "registrations" =>
        Enum.map(registrations, fn registration ->
          %{
            "id" => registration.id,
            "received_at" => DateTime.to_iso8601(registration.received_at),
            "payload" => registration.payload
          }
        end)
    })
  end
end
