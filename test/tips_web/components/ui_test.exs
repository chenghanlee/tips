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

  defp form_field(params, errors) do
    form = to_form(params, as: :review, errors: errors, action: :validate)
    form[:body]
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

  describe "setup_meta" do
    test "renders nonlinkable metadata and free-text models without links" do
      doc =
        html(&UI.setup_meta/1,
          technique: {"Planning", "/?technique=planning"},
          model: {:curated, "Claude Opus 5.5", "/?model=opus"},
          environment: {"Claude Code", "/?environment=claude-code"},
          linkable: false
        )

      assert count(doc, "a") == 0
      assert text(doc, "span") =~ "Claude Opus 5.5"

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
    test "pending votes ignore clicks while selected votes remain clickable" do
      doc = html(&UI.vote_control/1, target: "t1", pending: true, selected: nil)

      assert LazyHTML.attribute(LazyHTML.query(doc, "button"), "aria-disabled") == [
               "true",
               "true"
             ]

      assert count(doc, "button[disabled], button[phx-click]") == 0
      assert text(doc, "[role=status]") =~ "Saving"

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
end
