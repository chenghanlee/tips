defmodule TipsWeb.Markdown do
  @moduledoc """
  Renders authored tip and review Markdown with MDEx's Ammonia sanitizer, using
  the options in backend-design.md, "Markdown, embeds and secure headers".

  Raw HTML is omitted and the sanitizer keeps only the listed tags, link
  `href`/`title` and the http, https and mailto schemes, adding `rel` to every
  link. Syntax highlighting stays off (MDEx's default), so no class or style
  survives. Only this sanitized output is marked HTML-safe; titles, metadata
  and Prompt/Result text render as escaped text elsewhere.
  """

  # Strikethrough and tables produce the `del` and `table` tags the allowlist names.
  @options [
    extension: [strikethrough: true, table: true],
    render: [unsafe: false],
    sanitize: [
      tags:
        ~w(p br hr h1 h2 h3 h4 h5 h6 blockquote ul ol li pre code em strong del a table thead tbody tr th td),
      tag_attributes: %{"a" => ~w(href title)},
      generic_attributes: [],
      url_schemes: ~w(http https mailto),
      link_rel: "nofollow noopener noreferrer"
    ]
  ]

  @doc "Renders `markdown` to sanitized, HTML-safe output."
  @spec to_html(String.t()) :: Phoenix.HTML.safe()
  def to_html(markdown) when is_binary(markdown) do
    {:safe, MDEx.to_html!(markdown, @options)}
  end
end
