defmodule OpenResults.Markdown do
  @moduledoc """
  Markdown to HTML, for `OpenResults.Changelog`.

  Ported from `PairingsEngine.Markdown` verbatim in substance - see that
  module for the full history. In short: this used to be a call to
  `Earmark.as_html/1`, and Earmark is retired (every release, with no fixed
  version to move to) and carries CVE-2026-48591, a stored XSS through
  unescaped HTML attribute values. `earmark_parser` - maintained, pure
  Elixir, and the half of Earmark that never had the flaw, since the flaw is
  in HTML generation rather than parsing - does the parse, and this module
  does the generation, with escaping that is not optional and a closed tag
  set.

  The only input this site ever hands it is its own `CHANGELOG.md`, read at
  compile time, so the CVE was already unreachable here too - but an
  abandoned dependency with a permanent advisory is a line every future
  audit has to re-explain, and there is no reason for two applications in
  this family to carry it once one of them has already done the work of
  removing it.
  """

  # Everything CHANGELOG.md actually produces, and nothing else. A tag not
  # on this list is not "rejected" - its children still render, so dropping
  # one loses formatting rather than content.
  @tags ~w(
    h1 h2 h3 h4 h5 h6 p br hr
    ul ol li
    strong em code pre
    a
    table thead tbody tr th td
    blockquote del
  )

  # No closing tag, and no children to render.
  @void ~w(br hr img)

  @doc """
  Renders `markdown` to an HTML string.

  Returns the HTML, or a short error paragraph if the parser cannot read
  the input at all - never raises, because the only caller runs at compile
  time and a changelog that fails to parse should not stop the build.
  """
  def to_html(markdown) when is_binary(markdown) do
    case EarmarkParser.as_ast(markdown, gfm: true, breaks: false) do
      {:ok, ast, _messages} -> render(ast)
      {:error, ast, _messages} -> render(ast)
    end
  rescue
    _ -> "<p>Could not render the markdown.</p>"
  end

  defp render(nodes) when is_list(nodes), do: nodes |> Enum.map(&render/1) |> Enum.join()

  # A text node. Escaped, always - this is the one branch that decides
  # whether markdown source can become markup.
  defp render(text) when is_binary(text), do: escape_text(text)

  defp render({tag, attrs, children, _meta}) do
    cond do
      tag not in @tags ->
        render(children)

      tag in @void ->
        "<" <> tag <> attributes(attrs, tag) <> " />"

      true ->
        "<" <>
          tag <>
          attributes(attrs, tag) <> scope(tag) <> ">" <> render(children) <> "</" <> tag <> ">"
    end
  end

  # Anything the parser emits that is not a tuple or a binary (it should not,
  # but a renderer that crashes on an unexpected node is worse than one that
  # skips it).
  defp render(_other), do: ""

  # A markdown table's header cells are only ever its first row, so each one
  # heads a column - said outright, as every other table on this site does.
  defp scope("th"), do: ~s( scope="col")
  defp scope(_tag), do: ""

  defp attributes(attrs, tag) do
    attrs
    |> Enum.filter(fn {name, value} -> keep_attribute?(tag, name, value) end)
    |> Enum.map_join(fn {name, value} ->
      " " <> name <> ~s(=") <> escape_attribute(to_string(value)) <> ~s(")
    end)
  end

  # `href` and `src` are the only attributes that can carry a scheme, so they
  # are the only ones with a scheme rule.
  defp keep_attribute?(_tag, name, value) when name in ["href", "src"],
    do: safe_url?(to_string(value))

  # Attribute NAMES are not escapable - an attacker-supplied name is a new
  # attribute, not a value - so the names are a closed set too. `style` is on
  # it only because earmark_parser puts table alignment there.
  defp keep_attribute?(_tag, name, _value), do: name in ~w(class style title id)

  defp safe_url?(url) do
    trimmed = url |> String.trim() |> String.downcase()

    cond do
      String.starts_with?(trimmed, "http://") -> true
      String.starts_with?(trimmed, "https://") -> true
      String.starts_with?(trimmed, "mailto:") -> true
      # A relative link, an anchor, or a bare path. Rejected if it contains a
      # colon before the first slash, which is how a scheme is spelled.
      String.contains?(trimmed, ":") -> false
      true -> true
    end
  end

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attribute(value) do
    value
    |> escape_text()
    |> String.replace(~s("), "&quot;")
    |> String.replace("'", "&#39;")
  end
end
