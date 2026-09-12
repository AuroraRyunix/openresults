defmodule OpenResults.ChangelogTest do
  use ExUnit.Case, async: true

  alias OpenResults.Changelog

  test "renders the changelog to HTML at compile time" do
    html = Changelog.html()

    assert html =~ "<h2>"
    refute html =~ "was not found at compile time"
  end

  test "a real version heading is in there, not just an empty shell" do
    assert Changelog.html() =~ "0.1."
  end

  test "the tags render as pills, not as literal brackets" do
    html = Changelog.html()

    assert html =~ ~s(<span class="cl-tag cl-feature">Feature</span>)
    assert html =~ ~s(<span class="cl-tag cl-fix">Fix</span>)
  end

  describe "the renderer, which is ours rather than Earmark's" do
    test "escapes text rather than emitting it as markup" do
      html = OpenResults.Markdown.to_html(~s|A <script>alert(1)</script> line.|)

      refute html =~ "<script"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes attribute values" do
      html = OpenResults.Markdown.to_html(~s|[x](https://e.com/?a=") onload=alert)|)

      refute html =~ ~s|" onload=|
    end

    test "drops a javascript: link rather than rendering it" do
      html = OpenResults.Markdown.to_html("[click](javascript:alert(1))")

      refute html =~ "javascript:"
      assert html =~ "click"
    end

    test "still renders everything the changelog is made of" do
      html =
        OpenResults.Markdown.to_html("""
        # Title

        Some **bold** and `code` and a [link](https://example.com).

        - one
        - two

        | a | b |
        |---|---|
        | 1 | 2 |
        """)

      for tag <- ~w(h1 p strong code a ul li table thead tbody tr th td) do
        assert html =~ "<#{tag}", "the renderer stopped emitting <#{tag}>"
      end
    end
  end

  test "earmark is not a dependency" do
    # earmark_parser only - see OpenResults.Markdown's moduledoc. Asserted
    # rather than assumed, the same way OpenPairings guards it: absence
    # cannot quietly stop being true the way "nothing calls it" can.
    refute Code.ensure_loaded?(Earmark),
           "Earmark is on the load path - see OpenResults.Markdown for why it must not be."

    mix_exs = File.read!("mix.exs")

    refute mix_exs =~ ~r/\{:earmark,/,
           "mix.exs declares :earmark (:earmark_parser is the intended one)."
  end
end
