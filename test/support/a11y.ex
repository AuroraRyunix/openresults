defmodule OpenResultsWeb.A11y do
  @moduledoc """
  The accessibility invariants a rendered page can be held to without a
  browser.

  Started with the accessibility pass of 2026-09-13
  (`docs/accessibility-2026-09-13.md`). Everything here is DECIDABLE from the
  HTML alone - a control either has a label or it does not - which is what
  makes it worth running on every page on every test run. What only a person
  can judge (reading order, whether a label makes sense, what a screen reader
  actually says) is that document's manual checklist, not this module.

  `audit/2` returns a list of `{rule, detail}` violations, empty when the page
  is clean, so a failing test prints every problem on the page at once rather
  than the first one. `explain/1` turns that list into the failure message.

  ## The rules

    * `:lang` - `<html lang>` is set, and is the locale the page was asked
      for when `lang:` is given
    * `:title` - the document has a non-blank `<title>`
    * `:one_h1` - exactly one `<h1>`
    * `:heading_order` - no heading skips a level on the way down
    * `:main` - exactly one `<main>` landmark
    * `:skip_link` - the first focusable element is an in-page link to an
      element that exists
    * `:control_name` - every form control has an accessible name from a
      label, `aria-label`, `aria-labelledby` or `title`. A `placeholder` does
      not count: it disappears the moment somebody types
    * `:link_name` / `:button_name` - every link, button and `<summary>` has
      a name, ignoring anything `aria-hidden`
    * `:img_alt` - every `<img>` has an `alt` attribute, empty or not
    * `:svg` - every `<svg>` is `aria-hidden` or a named `role="img"`
    * `:table_headers` - every data `<table>` has header cells (a table marked
      `role="presentation"` is layout, not data, and is exempt from all three
      table rules)
    * `:th_scope` - every `<th>` says which way it points: `scope="col"` in a
      `<thead>`, `scope="row"` in a `<tbody>`
    * `:table_name` - every data `<table>` has a `<caption>` or an `aria-label`
    * `:tabindex` - no `tabindex` above 0
    * `:idref` - every `for`, `aria-labelledby`, `aria-describedby` and
      `aria-controls` points at an id on the page
    * `:duplicate_id` - no id appears twice
    * `:dialog` - a dialog has a name and says it is modal
    * `:hidden_focusable` - nothing focusable inside `aria-hidden="true"`
    * `:hidden_live_region` - no polite live region is rendered `hidden`.
      A region that is not in the accessibility tree when its text arrives
      is, in practice, not announced

  `skip:` takes a list of rule names for a page that legitimately differs.
  """

  @focusable_tags ~w(a button input select textarea summary iframe)
  @skipped_text_tags ~w(script style template select textarea option datalist)

  @type violation :: {atom(), String.t()}

  @doc "Every violation on `html`, a full document. Empty when the page is clean."
  @spec audit(String.t(), keyword()) :: [violation()]
  def audit(html, opts \\ []) when is_binary(html) do
    tree = html |> LazyHTML.from_document() |> LazyHTML.to_tree()
    elements = flatten(tree)
    ids = Enum.group_by(Enum.filter(elements, & &1.attrs["id"]), & &1.attrs["id"])

    ctx = %{
      elements: elements,
      ids: ids,
      labels: Enum.filter(elements, &(&1.tag == "label")),
      opts: opts
    }

    skip = Keyword.get(opts, :skip, [])

    [
      lang: &lang/1,
      title: &title/1,
      one_h1: &one_h1/1,
      heading_order: &heading_order/1,
      main: &main/1,
      skip_link: &skip_link/1,
      control_name: &control_name/1,
      link_name: &link_name/1,
      button_name: &button_name/1,
      img_alt: &img_alt/1,
      svg: &svg/1,
      table_headers: &table_headers/1,
      th_scope: &th_scope/1,
      table_name: &table_name/1,
      tabindex: &tabindex/1,
      idref: &idref/1,
      duplicate_id: &duplicate_id/1,
      dialog: &dialog/1,
      hidden_focusable: &hidden_focusable/1,
      hidden_live_region: &hidden_live_region/1
    ]
    |> Enum.reject(fn {rule, _check} -> rule in skip end)
    |> Enum.flat_map(fn {rule, check} -> Enum.map(check.(ctx), &{rule, &1}) end)
  end

  @doc "A failure message listing every violation, one per line."
  @spec explain([violation()]) :: String.t()
  def explain(violations) do
    Enum.map_join(violations, "\n", fn {rule, detail} -> "  #{rule}: #{detail}" end)
  end

  # ---------------------------------------------------------------------------
  # The rules

  defp lang(ctx) do
    case find(ctx, "html") do
      [%{attrs: %{"lang" => lang}}] when lang != "" ->
        wanted = ctx.opts[:lang]
        if wanted && wanted != lang, do: ["<html lang=#{lang}>, expected #{wanted}"], else: []

      _no_lang ->
        ["<html> has no lang"]
    end
  end

  defp title(ctx) do
    titles = for t <- find(ctx, "title"), Enum.any?(t.ancestors, &(&1.tag == "head")), do: t

    if Enum.any?(titles, &(not blank?(text(&1.children)))),
      do: [],
      else: ["no <title>, or a blank one"]
  end

  defp one_h1(ctx) do
    case length(find(ctx, "h1")) do
      1 -> []
      n -> ["#{n} <h1> elements"]
    end
  end

  defp heading_order(ctx) do
    ctx.elements
    |> Enum.filter(&(&1.tag in ~w(h1 h2 h3 h4 h5 h6)))
    |> Enum.map(&{heading_level(&1), squish(text(&1.children))})
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{previous, _}, {level, words}] ->
      if level > previous + 1,
        do: ["h#{level} \"#{words}\" follows an h#{previous}"],
        else: []
    end)
  end

  defp main(ctx) do
    case Enum.count(ctx.elements, &(&1.tag == "main" or &1.attrs["role"] == "main")) do
      1 -> []
      n -> ["#{n} main landmarks"]
    end
  end

  # The first element a Tab can actually reach: a button inside a `hidden`
  # banner is in the markup first and still not where the keyboard starts.
  defp skip_link(ctx) do
    case Enum.find(ctx.elements, &(focusable?(&1) and not inside_hidden?(&1))) do
      %{tag: "a", attrs: %{"href" => "#" <> target}} = link when target != "" ->
        cond do
          not Map.has_key?(ctx.ids, target) ->
            ["the skip link points at ##{target}, which is not on the page"]

          blank?(name(link, ctx)) ->
            ["the skip link has no text"]

          true ->
            []
        end

      nil ->
        []

      first ->
        ["the first focusable element is #{describe(first)}, not a skip link"]
    end
  end

  defp control_name(ctx) do
    for el <- ctx.elements, control?(el), blank?(control_label(el, ctx)) do
      "#{describe(el)} has no accessible name"
    end
  end

  defp link_name(ctx) do
    for %{tag: "a"} = el <- ctx.elements, Map.has_key?(el.attrs, "href"), blank?(name(el, ctx)) do
      "#{describe(el)} has no accessible name"
    end
  end

  defp button_name(ctx) do
    for el <- ctx.elements,
        el.tag in ~w(button summary) or el.attrs["role"] == "button",
        blank?(name(el, ctx)) do
      "#{describe(el)} has no accessible name"
    end
  end

  defp img_alt(ctx) do
    for %{tag: "img"} = el <- ctx.elements, not Map.has_key?(el.attrs, "alt") do
      "#{describe(el)} has no alt"
    end
  end

  defp svg(ctx) do
    for %{tag: "svg"} = el <- ctx.elements,
        not inside_svg?(el),
        el.attrs["aria-hidden"] != "true",
        not (el.attrs["role"] == "img" and not blank?(svg_name(el, ctx))) do
      "#{describe(el)} is neither aria-hidden nor a named role=img"
    end
  end

  # A table laid out for position rather than data says so with
  # `role="presentation"`, and is then not a table to a screen reader at all.
  defp data_tables(ctx),
    do: Enum.reject(find(ctx, "table"), &(&1.attrs["role"] in ["presentation", "none"]))

  defp table_headers(ctx) do
    for table <- data_tables(ctx), own(ctx, table, "th") == [] do
      "#{describe(table)} has no header cells"
    end
  end

  defp th_scope(ctx) do
    for table <- data_tables(ctx),
        th <- own(ctx, table, "th"),
        message = scope_problem(th),
        message != nil,
        do: message
  end

  defp table_name(ctx) do
    for table <- data_tables(ctx),
        blank?(table.attrs["aria-label"]),
        blank?(labelledby(table, ctx)),
        not Enum.any?(own(ctx, table, "caption"), &(not blank?(text(&1.children)))) do
      "#{describe(table)} has no caption or aria-label"
    end
  end

  defp tabindex(ctx) do
    for el <- ctx.elements,
        index = el.attrs["tabindex"],
        index != nil,
        match?({n, ""} when n > 0, Integer.parse(index)) do
      "#{describe(el)} has tabindex=#{index}"
    end
  end

  defp idref(ctx) do
    for el <- ctx.elements,
        attr <- ~w(for aria-labelledby aria-describedby aria-controls),
        value = el.attrs[attr],
        value != nil,
        id <- String.split(value),
        not Map.has_key?(ctx.ids, id) do
      "#{describe(el)} #{attr}=\"#{id}\" points at nothing"
    end
  end

  defp duplicate_id(ctx) do
    for {id, [_, _ | _]} <- ctx.ids, do: "id=\"#{id}\" appears more than once"
  end

  defp dialog(ctx) do
    Enum.flat_map(ctx.elements, fn el ->
      cond do
        el.attrs["role"] not in ["dialog", "alertdialog"] and el.tag != "dialog" ->
          []

        blank?(el.attrs["aria-label"]) and blank?(labelledby(el, ctx)) ->
          ["#{describe(el)} has no name"]

        el.tag != "dialog" and el.attrs["aria-modal"] != "true" ->
          ["#{describe(el)} does not say aria-modal=\"true\""]

        true ->
          []
      end
    end)
  end

  defp hidden_focusable(ctx) do
    for el <- ctx.elements,
        focusable?(el),
        Enum.any?(el.ancestors, &(&1.attrs["aria-hidden"] == "true")) do
      "#{describe(el)} is focusable inside aria-hidden"
    end
  end

  defp hidden_live_region(ctx) do
    for el <- ctx.elements,
        el.attrs["aria-live"] in ["polite", "assertive"] or el.attrs["role"] in ["status", "log"],
        Map.has_key?(el.attrs, "hidden") do
      "#{describe(el)} is a live region rendered hidden"
    end
  end

  # ---------------------------------------------------------------------------
  # Names

  # What a link, a button or a summary is called: roughly the accessible name
  # computation, conservative where the real one is generous.
  defp name(el, ctx) do
    first_present([
      labelledby(el, ctx),
      el.attrs["aria-label"],
      text(el.children),
      el.attrs["title"]
    ])
  end

  defp control_label(%{tag: "input", attrs: %{"type" => type}} = el, _ctx)
       when type in ["submit", "reset", "button"],
       do: first_present([el.attrs["aria-label"], el.attrs["value"]])

  defp control_label(%{tag: "input", attrs: %{"type" => "image"}} = el, _ctx),
    do: first_present([el.attrs["aria-label"], el.attrs["alt"]])

  defp control_label(el, ctx) do
    for_labels =
      case el.attrs["id"] do
        nil -> []
        id -> for label <- ctx.labels, label.attrs["for"] == id, do: text(label.children)
      end

    wrapping = for %{tag: "label"} = label <- el.ancestors, do: text(label.children)

    first_present(
      [labelledby(el, ctx), el.attrs["aria-label"]] ++
        for_labels ++ wrapping ++ [el.attrs["title"]]
    )
  end

  defp labelledby(el, ctx) do
    case el.attrs["aria-labelledby"] do
      nil ->
        nil

      ids ->
        ids
        |> String.split()
        |> Enum.flat_map(&Map.get(ctx.ids, &1, []))
        |> Enum.map_join(" ", &text(&1.children))
        |> nil_if_blank()
    end
  end

  defp svg_name(el, ctx) do
    title = for {"title", _attrs, children} <- el.children, do: text(children)
    first_present([labelledby(el, ctx), el.attrs["aria-label"] | title])
  end

  # The text a name would be built from: nothing a screen reader is told to
  # skip, the alt of an image, and not the options of a select or the body of
  # a script.
  defp text(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &text/1)
  defp text(binary) when is_binary(binary), do: binary
  defp text({:comment, _}), do: ""

  defp text({tag, attrs, children}) do
    attrs = Map.new(attrs)

    cond do
      tag in @skipped_text_tags -> ""
      attrs["aria-hidden"] == "true" -> ""
      Map.has_key?(attrs, "hidden") -> ""
      tag == "img" -> attrs["alt"] || ""
      not blank?(attrs["aria-label"]) -> attrs["aria-label"]
      true -> text(children)
    end
  end

  defp text(_other), do: ""

  # ---------------------------------------------------------------------------
  # The tree

  defp flatten(tree), do: tree |> walk([], []) |> Enum.reverse()

  defp walk(nodes, ancestors, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &walk(&1, ancestors, &2))

  defp walk({tag, attrs, children}, ancestors, acc) when is_binary(tag) do
    element = %{
      ref: System.unique_integer([:positive, :monotonic]),
      tag: tag,
      attrs: Map.new(attrs),
      children: children,
      ancestors: ancestors
    }

    walk(children, [element | ancestors], [element | acc])
  end

  defp walk(_text_or_comment, _ancestors, acc), do: acc

  defp find(ctx, tag), do: Enum.filter(ctx.elements, &(&1.tag == tag))

  # A table's own cells and caption - not those of a table nested inside one
  # of its cells, which answers for itself.
  defp own(ctx, table, tag) do
    Enum.filter(ctx.elements, fn el ->
      el.tag == tag and Enum.find_value(el.ancestors, &(&1.tag == "table" && &1.ref)) == table.ref
    end)
  end

  defp control?(%{tag: "input", attrs: attrs}), do: attrs["type"] != "hidden"
  defp control?(%{tag: tag}), do: tag in ~w(select textarea)

  defp focusable?(%{attrs: attrs} = el) do
    cond do
      Map.has_key?(attrs, "disabled") -> false
      attrs["tabindex"] == "-1" -> false
      Map.has_key?(attrs, "tabindex") -> true
      el.tag == "a" -> Map.has_key?(attrs, "href")
      el.tag == "input" -> attrs["type"] != "hidden"
      true -> el.tag in @focusable_tags
    end
  end

  defp inside_svg?(el), do: Enum.any?(el.ancestors, &(&1.tag == "svg"))

  defp inside_hidden?(el),
    do:
      Map.has_key?(el.attrs, "hidden") or
        Enum.any?(el.ancestors, &Map.has_key?(&1.attrs, "hidden"))

  defp scope_problem(th) do
    section = Enum.find_value(th.ancestors, &(&1.tag in ~w(thead tbody tfoot) && &1.tag))
    scope = th.attrs["scope"]

    case {section, scope} do
      {"thead", scope} when scope in ["col", "colgroup"] -> nil
      {"tbody", scope} when scope in ["row", "rowgroup"] -> nil
      {"tfoot", scope} when scope in ["col", "row"] -> nil
      {section, scope} -> "#{describe(th)} in <#{section}> has scope=#{inspect(scope)}"
    end
  end

  defp heading_level(%{tag: "h" <> n}), do: String.to_integer(n)

  defp describe(el) do
    words = el.children |> text() |> squish() |> String.slice(0, 40)

    attrs =
      ~w(id class name type href for)
      |> Enum.filter(&el.attrs[&1])
      |> Enum.map_join("", &~s( #{&1}="#{el.attrs[&1]}"))

    ~s(<#{el.tag}#{attrs}>) <> if(words == "", do: "", else: ~s( "#{words}"))
  end

  defp first_present(values), do: Enum.find_value(values, &nil_if_blank/1)

  defp nil_if_blank(value), do: if(blank?(value), do: nil, else: value)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""

  defp squish(value), do: value |> String.split() |> Enum.join(" ")
end
