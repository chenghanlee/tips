defmodule TipsWeb.EditorTest do
  @moduledoc """
  Acceptance evidence for #78 and #79 at the page: the editors' form identity
  and draft record, review setup defaults, the restore and reconnect events
  the `EditorDraft` hook and LiveView form recovery send, and submit-time
  validation and refused saves. The hook itself is in
  `TipsWeb.EditorDraftTest` and `TipsWeb.EditorSubmitTest`.
  """
  use TipsWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.VisibilityFixtures
  import TipsWeb.ReaderPageHelpers

  alias Tips.Accounts.UserToken
  alias Tips.Content.{Review, Tip}
  alias Tips.Repo

  setup :register_and_log_in_user

  test "a fresh review starts with the tip's setup once; restored and recovered blanks stay blank",
       %{conn: conn, user: user} do
    tip = tip_fixture(user_fixture(), %{model_other: "local-qwen-coder", environment_id: "ide"})
    path = "/editor/tips/#{tip.id}/reviews/new"

    for {render, html, _title} <- renders(conn, path) do
      assert selected(html, "review[model_id]") == "other", render
      assert value(html, "review[model_other]") == "local-qwen-coder", render
      assert selected(html, "review[environment_id]") == "ide", render
    end

    {:ok, lv, html} = live(conn, path)
    form_id = "#editor-#{user.id}-review"
    record = record(html, form_id)

    assert %{
             "storage" => %{"account_id" => account_id, "slot" => slot},
             "draft" => %{"draft_id" => key, "revision" => 0},
             "mode" => "new",
             "target" => %{"tag" => "new_review", "tip_id" => tip_id} = slot,
             "submission_key" => key,
             "intent" => %{
               "attrs" => %{"model_other" => "local-qwen-coder", "environment_id" => "ide"},
               "uploads" => []
             },
             "base" => nil,
             "expected_version" => nil
           } = record

    assert {account_id, tip_id} == {user.id, tip.id}

    # The saved draft cleared both setup fields.
    saved =
      put_in(record, ["intent", "attrs"], %{
        "body" => "Worked on a rename.",
        "model_id" => nil,
        "model_other" => nil,
        "environment_id" => "",
        "prompt" => nil,
        "output" => nil
      })

    render_hook(lv, "editor:restore", %{"identity" => identity(html, form_id), "record" => saved})
    assert_reply(lv, %{status: "restored"})
    html = render(lv)
    assert textarea(html, "review[body]") == "Worked on a rename."
    assert selected(html, "review[model_id]") == nil
    assert selected(html, "review[environment_id]") == nil

    # A later change and a reconnect keep the blanks.
    html =
      lv
      |> form(form_id, review: %{body: "Worked on a rename. Twice."})
      |> render_change()

    assert selected(html, "review[model_id]") == nil

    {:ok, fresh, fresh_html} = live(conn, path)

    recover(fresh, fresh_html, form_id, html, %{
      "body" => "Worked.",
      "model_id" => "",
      "environment_id" => ""
    })

    html = render(fresh)
    assert record(html, form_id)["submission_key"] == key
    assert selected(html, "review[model_id]") == nil
    assert selected(html, "review[environment_id]") == nil
  end

  test "Publish validates untouched fields, keeps long input and revalidates only after a failure",
       %{conn: conn, user: user} do
    form_id = "#editor-#{user.id}-tip"
    {:ok, lv, html} = live(conn, "/editor/tips/new")
    refute html =~ "maxlength"

    # Typing before the first submit shows no errors.
    html = lv |> form(form_id, tip: %{title: "Plan first", body: ""}) |> render_change()
    refute has?(html, "[aria-invalid]")

    long = String.duplicate("Plan. ", 3_400)
    html = lv |> form(form_id, tip: %{body: long}) |> render_submit()

    assert_push_event(lv, "editor:refused", %{})
    assert summary_links(html, form_id) == ["#tip_body", "#tip_tag_id"]
    # The technique was never touched.
    assert has?(html, ~s(#tip_tag_id[aria-invalid="true"]))
    refute has?(html, ~s(#tip_title[aria-invalid]))
    assert value(html, "tip[title]") == "Plan first"
    assert textarea(html, "tip[body]") == long

    # Correcting the body clears its error; the technique's stays.
    html = lv |> form(form_id, tip: %{body: "Plan before you prompt."}) |> render_change()
    assert summary_links(html, form_id) == ["#tip_tag_id"]
    refute has?(html, ~s(#tip_body[aria-invalid]))

    html = lv |> form(form_id, tip: %{tag_id: "other"}) |> render_submit()
    refute has?(html, "[aria-invalid]")
    assert text(html, "#{form_id}-outcome") == "Published"

    assert [%Tip{title: "Plan first", body: "Plan before you prompt.", tag_id: "other"}] =
             Repo.all(from t in Tip, where: t.user_id == ^user.id)
  end

  test "an expired sign-in or a full ban refuses Publish and keeps the input", %{
    conn: conn,
    user: user
  } do
    tip = tip_fixture()
    path = "/editor/tips/#{tip.id}/reviews/new"
    form_id = "#editor-#{user.id}-review"
    {:ok, lv, _html} = live(conn, path)

    # The session ended without a disconnect reaching this page.
    Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)
    html = lv |> form(form_id, review: %{body: "Worked on a rename."}) |> render_submit()

    assert text(html, "#{form_id}-refusal") =~ "Your sign-in has expired"

    assert attr(html, "#{form_id}-refusal a", "Sign in", "href") ==
             "/users/log-in?" <> URI.encode_query(return_to: path)

    assert textarea(html, "review[body]") == "Worked on a rename."

    # Signing in again publishes nothing by itself.
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), path)
    refute Repo.exists?(Review)

    full_ban!(user)
    html = lv |> form(form_id, review: %{body: "Worked on a rename."}) |> render_submit()

    assert text(html, "#{form_id}-refusal") =~ "This account can't publish or edit"
    assert textarea(html, "review[body]") == "Worked on a rename."
    refute Repo.exists?(Review)
  end

  test "reconnect recovery keeps a new tip's key, its blanks and the typed values", %{
    conn: conn,
    user: user
  } do
    form_id = "#editor-#{user.id}-tip"
    {:ok, _lv, before} = live(conn, "/editor/tips/new")
    # Other technique is an ordinary choice.
    assert has?(before, ~s(select[name="tip[tag_id]"] option[value="other"]))

    {:ok, lv, fresh} = live(conn, "/editor/tips/new")
    refute record(fresh, form_id)["submission_key"] == record(before, form_id)["submission_key"]

    recover(lv, fresh, form_id, before, %{
      "title" => "  Plan first ",
      "body" => "",
      "tag_id" => "other"
    })

    html = render(lv)

    assert record(html, form_id)["submission_key"] == record(before, form_id)["submission_key"]
    # Recovery does not validate the blank body.
    refute has?(html, "[aria-invalid]")
    assert value(html, "tip[title]") == "  Plan first "
    assert textarea(html, "tip[body]") == ""
    assert selected(html, "tip[tag_id]") == "other"
  end

  test "reconnect recovery keeps an edit's base and version; another identity changes nothing",
       %{conn: conn, user: user} do
    review =
      review_fixture(tip_fixture(), %{user_id: user.id, body: "Saved body", model_id: "gpt"})

    path = "/editor/reviews/#{review.id}/edit"
    form_id = "#editor-#{user.id}-review"
    {:ok, _lv, before} = live(conn, path)

    assert %{
             "mode" => "edit",
             "target" => %{"tag" => "edit", "kind" => "review", "id" => id},
             "submission_key" => nil,
             "base" => %{
               "attrs" => %{"body" => "Saved body", "model_id" => "gpt"},
               "uploads" => []
             },
             "expected_version" => 1
           } = record(before, form_id)

    assert id == review.id

    {:ok, lv, fresh} = live(conn, path)
    recover(lv, fresh, form_id, before, %{"body" => "Edited", "model_id" => ""})
    html = render(lv)
    assert record(html, form_id)["draft"] == record(before, form_id)["draft"]
    assert record(html, form_id)["base"] == record(before, form_id)["base"]
    assert textarea(html, "review[body]") == "Edited"
    assert selected(html, "review[model_id]") == nil

    # Another account's identity and record are not this form's.
    other = user_fixture()

    foreign =
      before
      |> record(form_id)
      |> put_in(["storage", "account_id"], other.id)
      |> put_in(["intent", "attrs", "body"], "Not mine")

    {:ok, lv, fresh} = live(conn, path)

    render_hook(lv, "editor:recover", %{
      "editor" => %{
        "identity" => JSON.encode!(%{identity(fresh, form_id) | "account_id" => other.id}),
        "record" => JSON.encode!(foreign)
      },
      "review" => %{"body" => "Not mine"}
    })

    render_hook(lv, "editor:restore", %{
      "identity" => identity(fresh, form_id),
      "record" => foreign
    })

    assert_reply(lv, %{status: "rejected"})
    html = render(lv)
    assert textarea(html, "review[body]") == "Saved body"
    assert record(html, form_id)["draft"] == record(fresh, form_id)["draft"]

    # Save validates against the same rules, then saves at the loaded version.
    html = lv |> form(form_id, review: %{body: " "}) |> render_submit()
    assert_push_event(lv, "editor:refused", %{})
    assert summary_links(html, form_id) == ["#review_body"]

    html = lv |> form(form_id, review: %{body: "Edited"}) |> render_submit()
    assert text(html, "#{form_id}-outcome") == "Changes saved"
    assert %Review{body: "Edited", edit_version: 2} = Repo.get!(Review, review.id)
  end

  # What LiveView sends after a reconnect: the old page's hidden inputs with
  # the recovered field values.
  defp recover(lv, fresh, form_id, old, values) do
    kind = if form_id =~ "-tip", do: "tip", else: "review"

    assert identity(old, form_id) == identity(fresh, form_id)

    render_hook(lv, "editor:recover", %{
      "editor" => %{
        "identity" => hidden(old, "editor[identity]"),
        "record" => hidden(old, "editor[record]")
      },
      kind => values
    })
  end

  defp summary_links(html, form_id),
    do: html |> find("#{form_id}-errors a") |> LazyHTML.attribute("href")

  defp record(html, form_id), do: html |> data(form_id, "data-editor-record") |> JSON.decode!()

  defp identity(html, form_id),
    do: html |> data(form_id, "data-editor-identity") |> JSON.decode!()

  defp data(html, selector, name),
    do: html |> find(selector) |> LazyHTML.attribute(name) |> hd()

  defp hidden(html, name), do: value(html, name)

  defp value(html, name),
    do: html |> find(~s(input[name="#{name}"])) |> LazyHTML.attribute("value") |> hd()

  defp textarea(html, name),
    do: html |> find(~s(textarea[name="#{name}"])) |> LazyHTML.text() |> String.trim_leading("\n")

  defp selected(html, name) do
    case html
         |> find(~s(select[name="#{name}"] option[selected]))
         |> LazyHTML.attribute("value") do
      [value] when value != "" -> value
      _ -> nil
    end
  end
end
