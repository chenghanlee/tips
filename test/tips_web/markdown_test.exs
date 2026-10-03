defmodule TipsWeb.MarkdownTest do
  @moduledoc """
  Acceptance evidence for #77: authored Markdown renders through the
  backend-design allowlist, and only the sanitized result is HTML-safe.
  """
  use ExUnit.Case, async: true

  alias TipsWeb.Markdown

  defp render(markdown), do: markdown |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  defp tags(html) do
    ~r/<([a-z][a-z0-9]*)/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  test "renders normal Markdown" do
    html =
      render("""
      ## Steps

      1. **Ask** for a *plan*
      2. Use `mix test` and ~~skip~~ nothing

      > Quoted line

      ```
      code <kept> as text
      ```

      | Step | Test |
      |------|------|
      | one  | yes  |

      ---

      [Docs](https://example.com/docs "Guide") and [anchor](#steps) and [page](/tips/1/x)
      """)

    assert {:safe, _iodata} = Markdown.to_html("text")
    assert html =~ "<h2>Steps</h2>"
    assert html =~ "<ol>"
    assert html =~ "<strong>Ask</strong>"
    assert html =~ "<em>plan</em>"
    assert html =~ "<code>mix test</code>"
    assert html =~ "<del>skip</del>"
    assert html =~ "<blockquote>"
    assert html =~ "code &lt;kept&gt; as text"
    assert html =~ "<table>"
    assert html =~ "<hr"
    assert html =~ ~s(href="https://example.com/docs")
    assert html =~ ~s(title="Guide")
    assert html =~ ~s(href="#steps")
    assert html =~ ~s(href="/tips/1/x")

    allowed = ~w(p br hr h1 h2 h3 h4 h5 h6 blockquote ul ol li pre code em strong del a table
                 thead tbody tr th td)

    assert tags(html) -- allowed == []
    refute html =~ "class="
    refute html =~ "style="
  end

  test "omits raw HTML, images and malformed HTML" do
    html =
      render("""
      Before <script>alert(1)</script> after

      <div onclick="steal()">raw block</div>

      <iframe src="https://evil.example"></iframe>

      ![diagram](https://example.com/a.png)

      <img src=x onerror=alert(1)>

      <a href="https://example.com" target="_blank" style="color:red" onmouseover="x()">raw link</a>

      <b><i>unclosed <svg><form><input name=x>

      Trailing <p class="x">text
      """)

    for fragment <- ~w(<script <div <iframe <img <svg <form <input <b> <i> target= style= onclick
                       onerror onmouseover class=) do
      refute html =~ fragment, "found #{fragment} in #{html}"
    end

    assert html =~ "Before"
    assert html =~ "after"
  end

  test "drops script, data and encoded URLs; adds rel to links" do
    html =
      render("""
      [js](javascript:alert(1))
      [encoded](&#106;avascript:alert(1))
      [percent](java%73cript:alert(1))
      [vb](vbscript:msgbox(1))
      [data](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)
      [mail](mailto:a@example.com)
      [plain](http://example.com)
      <https://auto.example.com>
      """)

    refute html =~ ~r/javascript/i
    refute html =~ ~r/vbscript/i
    refute html =~ ~r/java%73cript/i
    refute html =~ "data:"
    assert html =~ ~s(href="mailto:a@example.com")
    assert html =~ ~s(href="http://example.com")

    links = Regex.scan(~r/<a [^>]*>/, html) |> List.flatten()
    assert [_, _ | _] = links
    assert Enum.all?(links, &(&1 =~ ~s(rel="nofollow noopener noreferrer")))
  end
end
