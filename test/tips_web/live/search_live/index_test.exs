defmodule TipsWeb.SearchLive.IndexTest do
  @moduledoc """
  Acceptance evidence for #58: `/search` renders one URL-driven result page,
  the same on the disconnected and first connected render.

  The embedding provider answers 503, so each search uses keyword ranking.
  """
  # BM25 corpus statistics include other sandbox transactions; page contents
  # need a fixed corpus, as in `Tips.Content.SearchTest`.
  use TipsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.SearchFixtures, only: [indexed_review!: 2, indexed_tip!: 2, stub_provider: 1]
  import TipsWeb.ReaderPageHelpers

  @moduletag :capture_log

  setup do
    stub_provider(fn conn, _input -> Plug.Conn.send_resp(conn, 503, "") end)
    %{author: user_fixture()}
  end

  test "renders the requested query, filters and page as readable rows", %{
    conn: conn,
    author: author
  } do
    tip =
      indexed_tip!(author, %{
        title: "Reproduce the flake first",
        tag_id: "workflow",
        model_other: "local-qwen",
        environment_id: "cli"
      })

    review = indexed_review!(tip, %{body: "The flake <b>loop</b> caught a race."})

    indexed_tip!(author, %{
      title: "Flake hunting in chat",
      tag_id: "workflow",
      environment_id: "chat"
    })

    indexed_tip!(author, %{title: "Unrelated advice", tag_id: "workflow", environment_id: "cli"})
    path = "/search?q=++flake++&technique=workflow&environment=cli"

    for {render, html, title} <- renders(conn, path) do
      assert squished(html, "#results-heading") ==
               "Results for “flake” · Technique: Workflow · Environment: CLI",
             render

      assert title =~ "flake · Search", render
      assert attr(html, "#q", "", "value") == "flake", render
      assert selected(html, "#technique") == "Workflow", render
      assert selected(html, "#model") == "All", render
      assert selected(html, "#environment") == "CLI", render

      assert [_row] = html |> find("#result-rows li") |> Enum.to_list(), render
      row = "#tip-#{tip.id}"

      assert attr(html, "#{row} a", "Reproduce the flake first", "href") ==
               "/tips/#{tip.id}/reproduce-the-flake-first",
             render

      for label <- ["Workflow", "CLI"] do
        assert attr(html, "#{row} a", label, "href") ==
                 "/search?environment=cli&q=flake&technique=workflow",
               render
      end

      refute attr(html, "#{row} a", "local-qwen", "href"), render
      assert text(html, row) =~ "local-qwen", render

      assert squished(html, "#{row} a[href='/reviews/#{review.id}']") ==
               "Review: The flake <b>loop</b> caught a race.",
             render

      refute html =~ "<b>loop</b>", render

      for selector <- ["img", "video", "iframe", "button"] do
        refute has?(html, "#{row} #{selector}"), "#{render} #{selector}"
      end

      assert text(html, "nav[aria-label=Pages] [aria-current=page]") == "Page 1", render
      refute has?(html, "a[rel=next]"), render
      refute html =~ ~r/\d+ results/, render

      assert attr(html, "#filters a", "Clear filters", "href") == "/search?q=flake", render
    end
  end

  test "a filtered search with no matches keeps the query and filters", %{
    conn: conn,
    author: author
  } do
    indexed_tip!(author, %{title: "Flake hunting", tag_id: "workflow"})

    for {render, html, _title} <- renders(conn, "/search?q=flake&technique=persona") do
      assert text(html, "#results-empty") == "No tips match these filters", render
      assert selected(html, "#technique") == "Persona", render
      assert attr(html, "#filters a", "Clear filters", "href") == "/search?q=flake", render
    end
  end

  test "submitting and filtering patch the URL; blank and unchanged submits do not search",
       %{conn: conn, author: author} do
    for n <- 1..21, do: indexed_tip!(author, %{title: "Flake fix #{n}", tag_id: "workflow"})
    {:ok, lv, _html} = live(conn, "/search?q=flake&technique=workflow&page=2")
    flush_provider_inputs()

    assert [_row] = lv |> render() |> find("#result-rows li") |> Enum.to_list()

    assert lv |> render() |> attr("nav a", "Previous", "href") ==
             "/search?q=flake&technique=workflow"

    # Typing alone sends nothing: the search field has no change binding.
    refute lv |> element("form[role=search]") |> render() =~ "phx-change"

    for blank <- ["", "  \t "] do
      html = lv |> form("form[role=search]", %{q: blank}) |> render_submit()
      assert text(html, "#q-error") == "Enter a task or keywords to search."

      assert squished(html, "#results-heading") ==
               "Results for “flake” · Technique: Workflow · Page 2"

      assert [_row] = html |> find("#result-rows li") |> Enum.to_list()
    end

    html = lv |> form("form[role=search]", %{q: " flake "}) |> render_submit()
    refute has?(html, "#q-error")
    refute_received {:provider_input, _input}

    lv |> form("form[role=search]", %{q: "flake fix"}) |> render_submit()
    assert_patch(lv, "/search?q=flake+fix&technique=workflow")
    assert_received {:provider_input, input}
    assert input =~ ~r/Query:flake fix$/

    lv |> form("#filters", %{technique: "workflow"}) |> render_change()
    refute_received {:provider_input, _input}

    lv |> form("#filters", %{technique: "", environment: "cli"}) |> render_change()
    assert_patch(lv, "/search?environment=cli&q=flake+fix")
  end

  test "invalid and out-of-window pages normalize the same way on both renders", %{
    conn: conn,
    author: author
  } do
    indexed_tip!(author, %{title: "Flake fix"})

    for page <- ["0", "-1", "x", "1.5"],
        {render, html, _title} <- renders(conn, "/search?q=flake&page=#{page}") do
      assert text(html, "nav[aria-label=Pages] [aria-current=page]") == "Page 1",
             inspect({page, render})

      assert [_row] = html |> find("#result-rows li") |> Enum.to_list()
    end

    for {page, previous} <- [{"2", "/search?q=flake"}, {"11", "/search?page=10&q=flake"}],
        {render, html, _title} <- renders(conn, "/search?q=flake&page=#{page}") do
      label = inspect({page, render})
      assert text(html, "#results-empty") == "No results on page #{page}.", inspect(label)
      assert attr(html, "nav a", "Previous", "href") == previous, inspect(label)
      assert attr(html, "nav a", "First page", "href") == "/search?q=flake", inspect(label)
    end

    flush_provider_inputs()
    renders(conn, "/search?q=flake&page=11")
    refute_received {:provider_input, _input}
  end

  test "a search failure offers Retry for the same page instead of no matches", %{
    conn: conn,
    author: author
  } do
    indexed_tip!(author, %{title: "Flake fix"})
    {:ok, lv, _html} = live(conn, "/search?q=flake")

    # The search relations become unresolvable until the path is restored.
    Tips.Repo.query!("SET LOCAL search_path = pg_catalog")
    html = lv |> form("#filters", %{environment: "cli"}) |> render_change()
    Tips.Repo.query!("SET LOCAL search_path TO DEFAULT")

    assert text(html, "#results-error") =~ "Couldn't load this page of results."
    refute has?(html, "#results-empty")
    refute has?(html, "#result-rows")
    assert squished(html, "#results-heading") == "Results for “flake” · Environment: CLI"

    html = lv |> element("#retry") |> render_click()
    assert text(html, "#results-empty") == "No tips match these filters"
  end

  test "without a query the page searches nothing", %{conn: conn} do
    for {render, html, title} <- renders(conn, "/search?q=+&technique=workflow") do
      assert title =~ "Search", render
      refute has?(html, "#results"), render
      assert selected(html, "#technique") == "Workflow", render
    end

    refute_received {:provider_input, _input}
  end

  defp squished(html, selector), do: html |> text(selector) |> String.split() |> Enum.join(" ")

  # The selected option's label; a select with none selected shows All.
  defp selected(html, select) do
    case text(html, "#{select} option[selected]") do
      "" -> "All"
      label -> label
    end
  end

  defp flush_provider_inputs do
    receive do
      {:provider_input, _input} -> flush_provider_inputs()
    after
      0 -> :ok
    end
  end
end
