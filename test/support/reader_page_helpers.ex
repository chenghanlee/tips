defmodule TipsWeb.ReaderPageHelpers do
  @moduledoc "Renders a reader page both ways and queries its HTML, for the #77 route tests."

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint TipsWeb.Endpoint

  @doc """
  Returns the disconnected render (`get/2`, full document) and the first
  connected render (`live/2`) of `path` as `{render, html, page_title}`.
  """
  def renders(conn, path) do
    dead = conn |> get(path) |> html_response(200)
    {:ok, lv, connected} = live(conn, path)

    [
      {:disconnected, dead, text(dead, "title")},
      {:connected, connected, page_title(lv)}
    ]
  end

  @doc "Signs `user` in on `conn`; `nil` stays anonymous."
  def as(conn, nil), do: conn
  def as(conn, user), do: TipsWeb.ConnCase.log_in_user(conn, user)

  def find(html, selector), do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)
  def has?(html, selector), do: not Enum.empty?(find(html, selector))
  def text(html, selector), do: html |> find(selector) |> LazyHTML.text() |> String.trim()

  @doc "The `name` attribute of the first `selector` match whose text is `label`."
  def attr(html, selector, label, name) do
    html
    |> find(selector)
    |> Enum.find(&(&1 |> LazyHTML.text() |> String.trim() == label))
    |> then(&(&1 && &1 |> LazyHTML.attribute(name) |> List.first()))
  end
end
