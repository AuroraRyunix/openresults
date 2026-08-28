defmodule OpenResultsWeb.RegistrationHTML do
  @moduledoc """
  The entry form's markup.

  Hand written against this app's own stylesheet, like the tables are. The
  scaffold's `<.input>` in `core_components.ex` is styled for daisyUI, which
  `assets/css/app.css` dropped on purpose - tens of kilobytes of component
  library for a site made of four tables and one form, loaded over a playing
  hall's wifi - so using it here would produce controls with class names
  nothing defines.

  The masthead comes from `OpenResultsWeb.TournamentHTML`. This is a page of a
  tournament and should carry the same head as the standings it links back to.
  """

  use OpenResultsWeb, :html

  import OpenResultsWeb.TournamentHTML, only: [masthead: 1]

  alias OpenResultsWeb.Tournament

  embed_templates "registration_html/*"

  @doc """
  The form itself.

  No `phx-` anything and no JavaScript: this page has to work on the phone of
  somebody standing in a corridor with one bar of signal, and a plain form
  post does. Validation is therefore entirely on the server, and the errors it
  returns have to be worth reading, because a round trip is what they cost.

  Every field is optional except a name and an email. That is not laziness
  about data quality - it is club chess. A player with no rating, no
  federation, no FIDE ID and no club is the ordinary case, and a form that
  demanded them would turn "not known" into "cannot enter".
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :slug, :string, required: true
  attr :rounds, :list, required: true, doc: "the rounds a bye may be requested for"
  attr :alarm, :string, default: nil, doc: "a failure that is not about one field"

  def entry_form(assigns) do
    ~H"""
    <.form
      for={@form}
      action={~p"/t/#{@slug}/register"}
      method="post"
      id="registration-form"
      class="entry-form"
      csrf_token={false}
    >
      <%!--
        No CSRF token, deliberately, and the router says why at length: a
        token that nothing on this server verifies would be decoration, and
        verifying one means a session cookie on a site that sets none.
      --%>
      <p :if={@alarm} class="alarm" role="alert">{@alarm}</p>

      <p :if={@form.errors != []} class="alarm" role="alert">
        Nothing has been sent. Fix what is marked below and send it again.
      </p>

      <.field
        field={@form[:name]}
        label="Name"
        hint={~s|Surname first, as it should appear on the pairing list: "De Vos, Ilse".|}
        required
        autocomplete="name"
      />

      <.field
        field={@form[:email]}
        type="email"
        label="Email"
        hint="Only the arbiter sees this. It is never shown on these pages and never
              travels in a published tournament - it is here so they can tell you
              whether you are in."
        required
        autocomplete="email"
        inputmode="email"
      />

      <.field
        field={@form[:rating]}
        type="text"
        label="Rating"
        hint="Whichever rating you play under. Leave it empty if you have none."
        inputmode="numeric"
      />

      <.field
        field={@form[:federation]}
        label="Federation"
        hint="The three-letter FIDE code, like BEL. Leave it empty if you are unsure."
        maxlength="3"
        autocomplete="country"
      />

      <.field
        field={@form[:fide_id]}
        type="text"
        label="FIDE ID"
        hint="The number on your FIDE profile, if you have one."
        inputmode="numeric"
      />

      <.field
        field={@form[:club]}
        label="Club"
        hint="The club you play for, if any."
        autocomplete="organization"
      />

      <.byes_field :if={@rounds != []} field={@form[:requested_byes]} rounds={@rounds} />

      <div class="actions">
        <button type="submit" id="registration-submit">Send to the arbiter</button>
        <a href={~p"/t/#{@slug}"} class="cancel">Cancel</a>
      </div>
    </.form>
    """
  end

  @doc """
  One labelled field, with its hint and whatever went wrong with it.

  The error sits under the input rather than in a list at the top, because a
  list at the top makes somebody count fields to work out which one it meant.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :hint, :string, default: nil

  attr :rest, :global, include: ~w(autocomplete inputmode maxlength pattern placeholder required)

  def field(assigns) do
    field = assigns.field
    errors = Enum.map(field.errors, &translate_error/1)

    described_by =
      [assigns.hint && "#{field.id}_hint", errors != [] && "#{field.id}_error"]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    assigns =
      assigns
      |> assign(:errors, errors)
      |> assign(:described_by, if(described_by == "", do: nil, else: described_by))

    ~H"""
    <div class={["field", @errors != [] && "field-wrong"]}>
      <label for={@field.id}>
        {@label}
        <span :if={@rest[:required]} class="required">required</span>
      </label>

      <input
        type={@type}
        id={@field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        aria-describedby={@described_by}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />

      <p :if={@errors != []} class="wrong" id={"#{@field.id}_error"}>
        {Enum.join(@errors, ". ")}
      </p>
      <p :if={@hint} class="hint" id={"#{@field.id}_hint"}>{@hint}</p>
    </div>
    """
  end

  @doc """
  The rounds a player can ask to sit out.

  Boxes rather than a text field, because the tournament already told us how
  many rounds it has and a list somebody types is a list somebody mistypes.
  Offered only when the rounds are known - a tournament whose payload does not
  say how long it is gets no bye question at all, which is honest, where a
  free-text box would be inviting an answer nobody can check.

  The wording is the whole design constraint in one sentence: ticking a box is
  a request, and the arbiter grants byes.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :rounds, :list, required: true

  def byes_field(assigns) do
    field = assigns.field
    errors = Enum.map(field.errors, &translate_error/1)

    # The value comes back as strings after a failed submission and as
    # integers from a changeset, so both are compared as text.
    chosen =
      case field.value do
        values when is_list(values) -> Enum.map(values, &to_string/1)
        _absent_or_wrong_shape -> []
      end

    assigns = assigns |> assign(:errors, errors) |> assign(:chosen, chosen)

    ~H"""
    <fieldset class={["field", @errors != [] && "field-wrong"]}>
      <legend>Rounds you already know you cannot play</legend>

      <div class="checks">
        <label :for={round <- @rounds} class="check">
          <input
            type="checkbox"
            name={@field.name <> "[]"}
            value={round}
            checked={to_string(round) in @chosen}
          />
          <span>{round}</span>
        </label>
      </div>

      <p :if={@errors != []} class="wrong">{Enum.join(@errors, ". ")}</p>
      <p class="hint">
        Asking is not the same as getting. What a missed round is worth - a
        half point, nothing at all - is the arbiter's decision and their
        tournament's rules, not this form's.
      </p>
    </fieldset>
    """
  end
end
