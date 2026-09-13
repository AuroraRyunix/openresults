defmodule OpenResultsWeb.Admin.AddressBlockController do
  @moduledoc """
  Address blocks: the live ones, adding one, and lifting one.

  ## Adding is two steps, because the second one has to count

  A block reaches everybody behind an address - a club's wifi or a mobile
  carrier can be many people - so the contract requires the panel to show how
  many installations were seen from it before the block is confirmed. That
  number depends on what was typed, so:

    1. `GET /admin/address-blocks/new` - the form.
    2. `POST /admin/address-blocks/new` - checks the input exactly as a block
       would be checked (`Moderation.change_block/4`), then shows the
       confirmation page with the normalised range and
       `Moderation.installations_seen_from/1` for it. Stores nothing, so it
       needs no confirmation of its own; invalid input comes back to the form.
    3. `POST /admin/address-blocks` - the confirmed block, behind
       `OpenResultsWeb.Admin.Confirmation` like every other action.

  A POST rather than a GET for step 2 so the reason, which can name people,
  never sits in a URL, a browser history or a proxy log.

  The expiry travels from step 2 to step 3 as the exact instant shown on the
  confirmation page, so what was confirmed is what is stored.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components, only: [render_not_found: 2, at: 1]

  alias OpenResults.Moderation
  alias OpenResultsWeb.Admin.{Confirmation, Params}

  plug Confirmation when action in [:create, :unblock]

  # The contract's ceiling: "always with an expiry of at most 30 days".
  @max_days 30

  def index(conn, _params) do
    render(conn, :index, page_title: "Address blocks", blocks: Moderation.list_blocks())
  end

  def new(conn, _params) do
    render_form(conn, %{"duration" => "7", "unit" => "days"}, %{})
  end

  def preview(conn, params) do
    values = form_values(params)
    actor = conn.assigns.admin

    {expires_at, expiry_error} =
      case expiry(values) do
        {:ok, expires_at} -> {expires_at, nil}
        :error -> {nil, :unreadable}
      end

    changeset = Moderation.change_block(values["address"], expires_at, values["reason"], actor)
    errors = errors(changeset, expiry_error)

    if errors == %{} do
      cidr = Ecto.Changeset.get_field(changeset, :cidr)

      render(conn, :confirm,
        page_title: "Block #{cidr}",
        cidr: cidr,
        expires_at: Ecto.Changeset.get_field(changeset, :expires_at),
        reason: Ecto.Changeset.get_field(changeset, :reason),
        seen: Moderation.installations_seen_from(cidr)
      )
    else
      render_form(conn, values, errors)
    end
  end

  def create(conn, params) do
    block = if is_map(params["block"]), do: params["block"], else: %{}
    values = Map.take(form_values(params), ["address", "reason"])

    with {:ok, expires_at} <- instant(block["expires_at"]),
         {:ok, created} <-
           Moderation.block_address(
             block["address"],
             expires_at,
             block["reason"],
             conn.assigns.admin
           ) do
      conn
      |> put_flash(:info, "Blocked #{created.cidr} until #{at(created.expires_at)}.")
      |> redirect(to: ~p"/admin/address-blocks")
    else
      :error -> render_form(conn, values, errors(nil, :unreadable))
      {:error, %Ecto.Changeset{} = changeset} -> render_form(conn, values, errors(changeset, nil))
    end
  end

  def confirm_unblock(conn, %{"id" => id}) do
    with_block(conn, id, fn block ->
      Confirmation.render_page(conn,
        title: "Lift the block on #{block.cidr}?",
        action: ~p"/admin/address-blocks/#{block.id}/unblock",
        button: "Lift block",
        cancel: ~p"/admin/address-blocks",
        danger: false,
        consequences: [
          "Blocked by #{block.created_by} on #{at(block.inserted_at)}, until " <>
            "#{at(block.expires_at)}, because: #{block.reason}",
          "Registration, creating tournaments and publishing from this range are allowed again " <>
            "at once."
        ]
      )
    end)
  end

  def unblock(conn, %{"id" => id}) do
    case Moderation.unblock(id, conn.assigns.admin) do
      {:ok, block} ->
        conn
        |> put_flash(:info, "Lifted the block on #{block.cidr}.")
        |> redirect(to: ~p"/admin/address-blocks")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Nothing changed: that block has already expired or been lifted.")
        |> redirect(to: ~p"/admin/address-blocks")
    end
  end

  # --- the form ----------------------------------------------------------------

  defp render_form(conn, values, errors) do
    conn
    |> put_status(if errors == %{}, do: :ok, else: :unprocessable_entity)
    |> render(:new, page_title: "Block an address", values: values, errors: errors)
  end

  defp form_values(params) do
    block = if is_map(params["block"]), do: params["block"], else: %{}

    Map.new(["address", "duration", "unit", "reason"], fn key ->
      {key, if(is_binary(block[key]), do: block[key], else: nil)}
    end)
  end

  # A whole number of hours or days. Anything longer than the ceiling is
  # passed on as just past it, so the refusal is the block's own - "at most 30
  # days" - rather than an arithmetic error on a number nobody meant.
  defp expiry(values) do
    with text when is_binary(text) <- Params.text(values["duration"]),
         {amount, ""} when amount > 0 <- Integer.parse(text),
         unit when unit in ["hours", "days"] <- values["unit"] do
      seconds = amount * if(unit == "hours", do: 3600, else: 86_400)
      seconds = min(seconds, (@max_days + 1) * 86_400)

      {:ok, DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)}
    else
      _unreadable -> :error
    end
  end

  defp instant(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp instant(_missing), do: :error

  # One sentence per field, written for the person at the form rather than
  # repeating the changeset's terse messages.
  defp errors(changeset, expiry_error) do
    from_changeset =
      case changeset do
        %Ecto.Changeset{errors: errors} ->
          errors
          |> Enum.reverse()
          |> Map.new(fn {field, {message, _opts}} -> {field, sentence(field, message)} end)

        nil ->
          %{}
      end

    case expiry_error do
      nil -> from_changeset
      :unreadable -> Map.put(from_changeset, :expires_at, sentence(:expires_at, :unreadable))
    end
  end

  defp sentence(:cidr, "can't be blank"), do: "Enter an IP address or a CIDR range."

  defp sentence(:cidr, _not_an_address),
    do:
      "That is not an IP address or a CIDR range. Write one address, like 203.0.113.7, or a " <>
        "range, like 203.0.113.0/24."

  defp sentence(:expires_at, "must be at most " <> _),
    do: "A block lasts at most #{@max_days} days."

  defp sentence(:expires_at, "must be in the future"), do: "The expiry must be in the future."

  defp sentence(:expires_at, _unreadable),
    do:
      "Say how long the block lasts: a whole number of hours or days, at most #{@max_days} days."

  defp sentence(:reason, "can't be blank"),
    do: "Give a reason. Whoever reads this block later, you included, will need it."

  defp sentence(:reason, "should be at most " <> _),
    do: "Keep the reason to 2000 characters."

  defp sentence(_field, message), do: message

  defp with_block(conn, id, fun) do
    case Enum.find(Moderation.list_blocks(), &(Integer.to_string(&1.id) == id)) do
      nil ->
        render_not_found(
          conn,
          "No live block has the id #{id}. It may have expired or been lifted."
        )

      block ->
        fun.(block)
    end
  end
end
