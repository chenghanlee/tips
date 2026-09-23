defmodule TipsWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TipsWeb.UI

  defp html(component, assigns), do: LazyHTML.from_fragment(render_component(component, assigns))

  defp parse(rendered), do: rendered |> rendered_to_string() |> LazyHTML.from_fragment()

  defp get_attr(doc, selector, name) do
    case LazyHTML.attribute(LazyHTML.query(doc, selector), name) do
      [value] -> value
      [] -> nil
    end
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  defp form_field(params, errors, name \\ :body) do
    form = to_form(params, as: :review, errors: errors, action: :validate)
    form[name]
  end

  describe "field" do
    test "hides errors until the input is used" do
      field = form_field(%{"body" => "", "_unused_body" => ""}, body: {"can't be blank", []})

      doc = html(&UI.field/1, field: field, label: "Review", helper: "Say what happened.")

      assert get_attr(doc, "textarea, input", "aria-invalid") == nil
      assert get_attr(doc, "input", "aria-describedby") == "review_body-help"
      assert count(doc, "#review_body-error") == 0
    end

    test "shows the server error with aria wiring once used, without maxlength or required" do
      field = form_field(%{"body" => ""}, body: {"can't be blank", []})

      doc = html(&UI.field/1, field: field, label: "Review", helper: "Say what happened.")

      assert get_attr(doc, "input", "aria-invalid") == "true"
      assert get_attr(doc, "input", "aria-describedby") == "review_body-error review_body-help"
      assert text(doc, "#review_body-error") =~ "can't be blank"
      assert text(doc, "#review_body-help") =~ "Say what happened."
      assert get_attr(doc, "label", "for") == "review_body"
      assert count(doc, "[maxlength], [required]") == 0
    end

    test "renders a textarea and a native select" do
      field = form_field(%{"body" => "hello"}, [])

      doc = html(&UI.field/1, field: field, label: "Review", type: "textarea", rows: 6)
      assert get_attr(doc, "textarea#review_body", "rows") == "6"
      assert text(doc, "textarea") =~ "hello"

      field = form_field(%{"sort" => "new"}, [], :sort)

      doc =
        html(&UI.field/1,
          field: field,
          label: "Sort",
          type: "select",
          options: [{"Hot", "hot"}, {"New", "new"}]
        )

      assert get_attr(doc, "select#review_sort option[selected]", "value") == "new"
    end
  end

  test "model_field shows the name input only while the select is other" do
    form = to_form(%{"model_id" => "opus", "model_other" => ""}, as: :review)
    options = [{"Not specified", ""}, {"Claude Opus 5.5", "opus"}, {"Other model…", "other"}]

    doc =
      html(&UI.model_field/1,
        select_field: form[:model_id],
        text_field: form[:model_other],
        options: options
      )

    assert count(doc, "select#review_model_id") == 1
    assert count(doc, "#review_model_other") == 0

    form = to_form(%{"model_id" => "other", "model_other" => "local-qwen"}, as: :review)

    doc =
      html(&UI.model_field/1,
        select_field: form[:model_id],
        text_field: form[:model_other],
        options: options
      )

    assert get_attr(doc, "input#review_model_other", "value") == "local-qwen"
    assert text(doc, "label[for=review_model_other]") =~ "Model name"
    assert text(doc, "#review_model_other-help") =~ "Up to 80 characters."
    assert count(doc, "[maxlength]") == 0
  end

  test "error_summary is a focusable alert linking to each field" do
    doc =
      html(&UI.error_summary/1,
        errors: [{"review_body", "Review: write it"}, {"review_output", "Result: too long"}]
      )

    assert get_attr(doc, "div", "role") == "alert"
    assert get_attr(doc, "div", "tabindex") == "-1"

    assert LazyHTML.attribute(LazyHTML.query(doc, "li a"), "href") == [
             "#review_body",
             "#review_output"
           ]

    assert text(doc, "h2") =~ "Fix 2 problems"
  end

  test "notice renders only the given role" do
    assigns = %{}

    assert get_attr(parse(~H|<UI.notice role="status">Loading</UI.notice>|), "div", "role") ==
             "status"

    assert get_attr(parse(~H"<UI.notice>Nothing yet</UI.notice>"), "div", "role") == nil

    doc =
      parse(~H"""
      <UI.notice role="alert" tone="error">
        Failed
        <:actions><button>Retry</button></:actions>
      </UI.notice>
      """)

    assert get_attr(doc, "div", "role") == "alert"
    assert count(doc, ".hero-exclamation-triangle") == 1
    assert text(doc, "button") =~ "Retry"
  end

  describe "page_nav" do
    test "hides Next when there is no next page" do
      doc = html(&UI.page_nav/1, page: 2, prev_href: "/?page=1", next_href: nil, first_href: "/")

      assert text(doc, "[aria-current=page]") =~ "Page 2"
      assert get_attr(doc, "a[rel=prev]", "href") == "/?page=1"
      assert count(doc, "a[rel=next]") == 0
    end

    test "offers Previous and First page when out of range" do
      doc =
        html(&UI.page_nav/1,
          page: 9,
          prev_href: "/?page=8",
          next_href: nil,
          first_href: "/",
          out_of_range: true
        )

      assert get_attr(doc, "a[rel=prev]", "href") == "/?page=8"
      assert text(doc, "a[href='/']") =~ "First page"
      assert count(doc, "[aria-current=page]") == 0
    end
  end

  describe "setup_meta" do
    test "renders a free-text model as text" do
      doc =
        html(&UI.setup_meta/1,
          technique: {"Planning", "/?technique=planning"},
          model: {:free_text, "local-qwen"},
          environment: {"Claude Code", "/?environment=claude-code"}
        )

      assert LazyHTML.text(LazyHTML.query(doc, "a")) =~ "Planning"
      assert count(doc, "a") == 2
      assert text(doc, "span") =~ "local-qwen"
    end

    test "renders everything as text when not linkable" do
      doc =
        html(&UI.setup_meta/1,
          technique: {"Planning", "/?technique=planning"},
          model: {:curated, "Claude Opus 5.5", "/?model=opus"},
          environment: {"Claude Code", "/?environment=claude-code"},
          linkable: false
        )

      assert count(doc, "a") == 0
      assert text(doc, "span") =~ "Claude Opus 5.5"
    end
  end

  test "tip_row keeps title, tag, model, author and excerpt links separate" do
    tip = %{
      id: "tip-1",
      title: "Ask for a plan",
      href: "/tips/1",
      net_score: 42,
      review_count: 12,
      age: "3 hours ago",
      datetime: "2026-09-23T09:10:00Z",
      author: %{handle: "ada", href: "/u/ada"},
      setup: %{
        technique: {"Planning", "/?technique=planning"},
        model: {:curated, "Claude Opus 5.5", "/?model=opus"}
      }
    }

    assigns = %{tip: tip}

    doc =
      parse(~H"""
      <UI.tip_row tip={@tip} vote={%{target: "tip-1", selected: :helpful}}>
        <:excerpt source="Review" href="/tips/1#r1">the loop caught a race</:excerpt>
      </UI.tip_row>
      """)

    assert count(doc, "a a") == 0
    assert count(doc, "a") == 5
    assert text(doc, "li") =~ "Net +42"
    assert text(doc, "li") =~ "12 reviews"
    assert text(doc, "a[href='/tips/1#r1']") =~ "Review:"
    assert get_attr(doc, "button[aria-pressed=true]", "aria-describedby") == "tip-1-title"
  end

  describe "vote_control" do
    test "pending sets aria-disabled on both buttons and ignores clicks" do
      doc = html(&UI.vote_control/1, target: "t1", pending: true, selected: nil)

      assert LazyHTML.attribute(LazyHTML.query(doc, "button"), "aria-disabled") == [
               "true",
               "true"
             ]

      assert count(doc, "button[disabled], button[phx-click]") == 0
      assert text(doc, "[role=status]") =~ "Saving"
    end

    test "detail variant shows counts and pressed state" do
      doc =
        html(&UI.vote_control/1,
          variant: "detail",
          target: "t1",
          selected: :not_helpful,
          counts: %{helpful: 8, not_helpful: 1}
        )

      assert LazyHTML.attribute(LazyHTML.query(doc, "button"), "aria-pressed") == [
               "false",
               "true"
             ]

      assert text(doc, "button") =~ "Helpful 8"
      assert text(doc, "button") =~ "Not helpful 1"
      assert LazyHTML.attribute(LazyHTML.query(doc, "button"), "phx-click") == ["vote", "vote"]
    end
  end

  test "disclosure renders details that keep their open attribute across patches" do
    assigns = %{}
    doc = parse(~H|<UI.disclosure id="d1" open summary="Prompt and result">body</UI.disclosure>|)

    assert get_attr(doc, "details#d1", "open") == ""
    assert get_attr(doc, "details#d1", "phx-mounted") =~ ~s(["ignore_attrs",{"attrs":["open"]}])
    assert text(doc, "summary") =~ "Prompt and result"

    closed = parse(~H|<UI.disclosure id="d1" summary="Prompt and result">body</UI.disclosure>|)
    assert get_attr(closed, "details#d1", "open") == nil
  end

  describe "site_header" do
    test "links to Tips and account pages" do
      doc = html(&UI.site_header/1, current_scope: nil)

      assert text(doc, "header a[href='/']") =~ "Tips"
      assert count(doc, "a[href='/users/log-in']") == 1
      assert count(doc, "a[data-phx-link]") > 0
    end

    test "editor exits are ordinary links" do
      doc = html(&UI.site_header/1, current_scope: nil, editor: true)

      assert count(doc, "a") > 1
      assert count(doc, "a[data-phx-link]") == 0
      assert count(doc, "a:not([href])") == 0
    end
  end

  test "search_form shows the blank message without required" do
    doc =
      html(&UI.search_form/1,
        value: "   ",
        error: "Enter a task or keywords to search.",
        action: "/search"
      )

    assert get_attr(doc, "form", "role") == "search"
    assert get_attr(doc, "input[type=search]", "aria-invalid") == "true"
    assert get_attr(doc, "input[type=search]", "aria-describedby") == "q-error q-help"
    assert text(doc, "#q-error") =~ "Enter a task or keywords to search."
    assert count(doc, "[required]") == 0
  end

  test "filter_bar shows Clear filters only when active" do
    assigns = %{}

    doc = parse(~H|<UI.filter_bar id="filters" active clear_href="/?sort=hot"></UI.filter_bar>|)
    assert text(doc, "a[href='/?sort=hot']") =~ "Clear filters"
    assert text(doc, "#filters-note") =~ "Changing a selection updates the list"

    doc =
      parse(
        ~H|<UI.filter_bar id="filters" active={false} clear_href="/?sort=hot"></UI.filter_bar>|
      )

    assert count(doc, "a") == 0
  end

  test "filter_select is a labelled native select" do
    doc =
      html(&UI.filter_select/1,
        id: "technique",
        name: "technique",
        label: "Technique",
        options: [{"All", ""}, {"Planning", "planning"}],
        value: "planning"
      )

    assert get_attr(doc, "label", "for") == "technique"
    assert get_attr(doc, "select#technique option[selected]", "value") == "planning"
  end
end
