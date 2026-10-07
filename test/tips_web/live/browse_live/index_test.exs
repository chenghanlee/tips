defmodule TipsWeb.BrowseLive.IndexTest do
  @moduledoc """
  Acceptance evidence for #97: `/` browses Hot or New tips with URL filters
  and pages, the same on the disconnected and first connected render.
  """
  use TipsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import TipsWeb.ReaderPageHelpers

  setup do
    %{author: user_fixture()}
  end

  test "renders the requested sort, filters and page as readable rows", %{
    conn: conn,
    author: author
  } do
    older = DateTime.add(DateTime.utc_now(:second), -1, :hour)

    tip =
      tip_fixture(author, %{
        title: "Reproduce the flake first",
        tag_id: "workflow",
        model_other: "local-qwen",
        environment_id: "cli",
        created_at: older
      })

    newer =
      tip_fixture(author, %{title: "Bisect the change", tag_id: "workflow", model_id: "claude"})

    tip_fixture(author, %{title: "Other technique", tag_id: "persona"})

    for {render, html, title} <- renders(conn, "/?sort=new&technique=workflow") do
      assert squished(html, "#feed-heading") == "New tips · Technique: Workflow", render
      assert title =~ "New tips", render
      assert selected(html, "#sort") == "New", render
      assert selected(html, "#technique") == "Workflow", render
      assert selected(html, "#model") == "All", render

      assert html |> find("#tip-rows li") |> Enum.map(&LazyHTML.attribute(&1, "id")) ==
               [["tip-#{newer.id}"], ["tip-#{tip.id}"]],
             render

      row = "#tip-#{tip.id}"

      assert attr(html, "#{row} a", "Reproduce the flake first", "href") ==
               "/tips/#{tip.id}/reproduce-the-flake-first",
             render

      # A curated label sets only its own filter and keeps the sort, on page 1.
      assert attr(html, "#{row} a", "Workflow", "href") == "/?sort=new&technique=workflow",
             render

      assert attr(html, "#{row} a", "CLI", "href") ==
               "/?environment=cli&sort=new&technique=workflow",
             render

      assert attr(html, "#tip-#{newer.id} a", "Claude", "href") ==
               "/?model=claude&sort=new&technique=workflow",
             render

      refute attr(html, "#{row} a", "local-qwen", "href"), render
      assert text(html, row) =~ "local-qwen", render

      for selector <- ["img", "video", "iframe"] do
        refute has?(html, "#{row} #{selector}"), "#{render} #{selector}"
      end

      assert text(html, "nav[aria-label=Pages] [aria-current=page]") == "Page 1", render
      refute has?(html, "a[rel=next]"), render
      refute html =~ ~r/\d+ (tips|results)/, render
      assert attr(html, "#filters a", "Clear filters", "href") == "/?sort=new", render
    end

    for {render, html, _title} <- renders(conn, "/") do
      assert squished(html, "#feed-heading") == "Hot tips", render
      assert selected(html, "#sort") == "Hot", render
      refute has?(html, "#filters a"), render
      assert attr(html, "#tip-#{tip.id} a", "Workflow", "href") == "/?technique=workflow", render
    end
  end

  test "select changes patch the URL on page 1; Clear filters keeps the sort", %{
    conn: conn,
    author: author
  } do
    for _n <- 1..21, do: tip_fixture(author, %{tag_id: "workflow"})
    {:ok, lv, _html} = live(conn, "/?sort=new&technique=workflow&page=2")

    html = render(lv)
    assert [_row] = html |> find("#tip-rows li") |> Enum.to_list()
    assert attr(html, "nav a", "Previous", "href") == "/?sort=new&technique=workflow"
    assert squished(html, "#feed-heading") == "New tips · Technique: Workflow · Page 2"

    # Selecting the applied values again changes nothing.
    lv |> form("#filters", %{sort: "new", technique: "workflow"}) |> render_change()
    refute_patched(lv)

    lv
    |> form("#filters", %{sort: "new", technique: "workflow", environment: "cli"})
    |> render_change()

    assert_patch(lv, "/?environment=cli&sort=new&technique=workflow")
    assert text(render(lv), "#tips-empty") == "No tips match these filters"

    lv |> form("#filters", %{sort: "hot", technique: "", environment: "cli"}) |> render_change()
    assert_patch(lv, "/?environment=cli")

    lv |> element("#filters a", "Clear filters") |> render_click()
    assert_patch(lv, "/")

    lv |> form("#filters", %{sort: "new"}) |> render_change()
    assert_patch(lv, "/?sort=new")
    assert [_ | _] = render(lv) |> find("#tip-rows li") |> Enum.to_list()
    assert render(lv) |> attr("nav a", "Next", "href") == "/?page=2&sort=new"
  end

  test "invalid pages normalize and an out-of-range page offers Previous and First", %{
    conn: conn,
    author: author
  } do
    tip_fixture(author)

    for page <- ["0", "-1", "x", "1.5"],
        {render, html, _title} <- renders(conn, "/?sort=new&page=#{page}") do
      label = inspect({page, render})
      assert text(html, "nav[aria-label=Pages] [aria-current=page]") == "Page 1", label
      assert [_row] = html |> find("#tip-rows li") |> Enum.to_list(), label
    end

    for {page, previous} <- [
          {"3", "/?page=2&sort=new"},
          {"99999999999999999999", "/?page=99999999999999999998&sort=new"}
        ],
        {render, html, _title} <- renders(conn, "/?sort=new&page=#{page}") do
      label = inspect({page, render})
      assert text(html, "#tips-empty") == "No tips on page #{page}.", label
      assert attr(html, "nav a", "Previous", "href") == previous, label
      assert attr(html, "nav a", "First page", "href") == "/?sort=new", label
    end
  end

  test "searching carries the filters to search without the sort; a blank search stays", %{
    conn: conn,
    author: author
  } do
    tip_fixture(author, %{title: "Kept row", tag_id: "workflow"})
    {:ok, lv, _html} = live(conn, "/?sort=new&technique=workflow&environment=cli")

    for blank <- ["", "  \t "] do
      html = lv |> form("form[role=search]", %{q: blank}) |> render_submit()
      assert text(html, "#q-error") == "Enter a task or keywords to search."
      assert selected(html, "#technique") == "Workflow"
    end

    assert {:error, {:live_redirect, %{kind: :push, to: to}}} =
             lv |> form("form[role=search]", %{q: "  flake  fix "}) |> render_submit()

    assert to == "/search?environment=cli&q=flake+fix&technique=workflow"
  end

  defp squished(html, selector), do: html |> text(selector) |> String.split() |> Enum.join(" ")

  # The selected option's label; a select with none selected shows its first.
  defp selected(html, select) do
    case text(html, "#{select} option[selected]") do
      "" -> html |> find("#{select} option") |> Enum.at(0) |> LazyHTML.text()
      label -> label
    end
  end
end
