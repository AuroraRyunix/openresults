defmodule OpenResultsWeb.Admin.ConfirmationHTML do
  @moduledoc """
  The confirmation page for a destructive admin action. See
  `OpenResultsWeb.Admin.Confirmation` for the pattern it belongs to.

  English only, not wrapped in gettext - see `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  alias OpenResultsWeb.Admin.Confirmation

  @doc """
  The form: a heading, whatever the slot says, and one button that posts.

  Everything inside the slot is inside the form, so extra inputs - a
  checkbox, a reason - are submitted with it. `<.form>` adds the CSRF token;
  the hidden `confirm` field names this form's own action, which is what
  `OpenResultsWeb.Admin.Confirmation` checks on the way back in.
  """
  attr :title, :string, required: true
  attr :action, :string, required: true, doc: "where the form posts"
  attr :button, :string, required: true, doc: "says what will happen, not \"OK\""
  attr :cancel, :string, required: true, doc: "where Cancel goes"
  attr :hidden, :map, default: %{}, doc: "extra hidden fields, name => value"
  attr :danger, :boolean, default: true
  slot :inner_block

  def confirmation(assigns) do
    ~H"""
    <.form
      for={%{}}
      action={@action}
      method="post"
      id="confirmation-form"
      class={["admin-confirm", @danger && "is-danger"]}
    >
      <h1>{@title}</h1>
      {render_slot(@inner_block)}
      <input type="hidden" name={Confirmation.field()} value={@action} />
      <input :for={{name, value} <- @hidden} type="hidden" name={name} value={value} />
      <div class="actions">
        <button type="submit" id="confirmation-submit">{@button}</button>
        <a href={@cancel} class="cancel" id="confirmation-cancel">Cancel</a>
      </div>
    </.form>
    """
  end

  @doc "The page `Confirmation.render_page/2` renders: sentences, then the form."
  def page(assigns) do
    ~H"""
    <.confirmation
      title={@title}
      action={@action}
      button={@button}
      cancel={@cancel}
      hidden={@hidden}
      danger={@danger}
    >
      <p :for={line <- @consequences} class="admin-consequence">{line}</p>
    </.confirmation>
    """
  end

  @doc "What a POST without its confirmation gets. Nothing has been done."
  def unconfirmed(assigns) do
    ~H"""
    <section id="confirmation-missing">
      <h1>Not confirmed</h1>
      <p>Nothing was changed. This action is only carried out from its own confirmation page.</p>
      <p><a href={@conn.request_path}>Go to the confirmation page</a></p>
    </section>
    """
  end
end
