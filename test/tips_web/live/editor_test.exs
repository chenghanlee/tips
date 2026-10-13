defmodule TipsWeb.EditorTest do
  @moduledoc """
  Acceptance evidence for #78, #79 and #80 at the page: the editors' form
  identity and draft record, review setup defaults, the restore and reconnect
  events the `EditorDraft` hook and LiveView form recovery send, submit-time
  validation and refused saves, and which receipts clear the submitted draft.
  The hook itself is in `TipsWeb.EditorDraftTest` and
  `TipsWeb.EditorSubmitTest`; a failed lookup is in
  `TipsWeb.EditorLookupTest`.
  """
  use TipsWeb.ConnCase, async: true
  use Oban.Testing, repo: Tips.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures
  import TipsWeb.ReaderPageHelpers

  alias Phoenix.LiveView.{UploadConfig, UploadEntry}
  alias Tips.Accounts.{Scope, UserToken}
  alias Tips.Content
  alias Tips.Content.Media.{Asset, R2}
  alias Tips.Content.{Review, Tip}
  alias Tips.R2Stub
  alias Tips.Repo
  alias Tips.Workers.CleanupMedia
  alias TipsWeb.Editor

  @png Path.expand("../../fixtures/images/static.png", __DIR__)

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
    assert text(html, "#{form_id}-errors") =~ "Tip: this is too long (max: 10000)"
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

    assert [%Tip{id: id, title: "Plan first", body: "Plan before you prompt.", tag_id: "other"}] =
             Repo.all(from t in Tip, where: t.user_id == ^user.id)

    # The hook clears the submitted draft, then the page leaves for the tip.
    key = record(html, form_id)["submission_key"]
    assert_push_event(lv, "editor:clear", %{draft_id: ^key})
    render_hook(lv, "editor:cleared", %{"status" => "ok"})
    assert_redirect(lv, "/tips/#{TipsWeb.TipId.encode(id)}/plan-first")
  end

  test "a long document, an expired sign-in or a full ban refuses Publish and keeps the input", %{
    conn: conn,
    user: user
  } do
    tip = tip_fixture()
    path = "/editor/tips/#{tip.id}/reviews/new"
    form_id = "#editor-#{user.id}-review"
    {:ok, lv, _html} = live(conn, path)

    # Each field is within its limit; together they are 30,001 bytes.
    long = %{body: String.duplicate("é", 10_000), prompt: String.duplicate("x", 10_000)}
    html = lv |> form(form_id, review: long) |> render_submit()

    assert text(html, "#{form_id}-refusal") =~
             "This review is too long. Shorten it by about 1 word."

    assert textarea(html, "review[body]") == long.body
    assert textarea(html, "review[prompt]") == long.prompt
    refute Repo.exists?(Review)

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
    assert %Review{body: "Edited", edit_version: 2} = Repo.get!(Review, review.id)
    draft_id = record(html, form_id)["draft"]["draft_id"]
    assert_push_event(lv, "editor:clear", %{draft_id: ^draft_id})
    render_hook(lv, "editor:cleared", %{"status" => "ok"})
    assert_redirect(lv, "/reviews/#{review.id}")
  end

  test "tabs sharing a key: only the published values clear their draft", %{
    conn: conn,
    user: user
  } do
    form_id = "#editor-#{user.id}-tip"
    values = %{title: "Plan first", body: "Plan before you prompt.", tag_id: "other"}
    {:ok, a, a_html} = live(conn, "/editor/tips/new")
    record = record(a_html, form_id)
    key = record["submission_key"]

    # Tab B restored the same draft before tab A published it.
    {:ok, b, b_html} = live(conn, "/editor/tips/new")

    render_hook(b, "editor:restore", %{
      "identity" => identity(b_html, form_id),
      "record" => record
    })

    assert_reply(b, %{status: "restored"})

    a |> form(form_id, tip: values) |> render_submit()
    assert %Tip{id: id} = Repo.get_by!(Tip, submission_key: key)
    to = "/tips/#{TipsWeb.TipId.encode(id)}/plan-first"
    assert_push_event(a, "editor:clear", %{draft_id: ^key, to: ^to})

    # Other work kept the draft: no navigation.
    html = render_hook(a, "editor:cleared", %{"status" => "conflict"})
    assert_reply(a, %{left: false})
    assert text(html, "#{form_id}-outcome") =~ "A different draft saved in this browser was kept"

    # Tab B's different values are not the publication.
    html = b |> form(form_id, tip: %{values | body: "Plan, then prompt."}) |> render_submit()
    refute_push_event(b, "editor:clear", _)
    assert text(html, "#{form_id}-refusal") =~ "This draft was published earlier"

    assert attr(html, "#{form_id}-refusal a", "View it", "href") ==
             "/tips/#{TipsWeb.TipId.encode(id)}/plan-first"

    assert textarea(html, "tip[body]") == "Plan, then prompt."

    # Reopening: the published values clear, an unknown selection does not.
    published =
      put_in(record, ["intent", "attrs"], Map.merge(record["intent"]["attrs"], json(values)))

    {:ok, c, c_html} = live(conn, "/editor/tips/new")

    render_hook(c, "editor:restore", %{
      "identity" => identity(c_html, form_id),
      "record" => published
    })

    assert_reply(c, %{status: "published", to: ^to})
    c_html = render(c)
    assert record(c_html, form_id)["submission_key"] == key

    # A reconnect before the clear settles still finds the publication.
    {:ok, c2, c2_html} = live(conn, "/editor/tips/new")
    recover(c2, c2_html, form_id, c_html, json(values))
    render_hook(c2, "editor:reconcile", %{})
    assert_push_event(c2, "editor:clear", %{draft_id: ^key, to: ^to})

    render_hook(c, "editor:cleared", %{"status" => "ok"})
    assert_redirect(c, to)

    {:ok, d, d_html} = live(conn, "/editor/tips/new")
    unknown = put_in(published, ["intent", "uploads"], nil)

    render_hook(d, "editor:restore", %{
      "identity" => identity(d_html, form_id),
      "record" => unknown
    })

    assert_reply(d, %{status: "restored"})
    refute_push_event(d, "editor:clear", _)
    assert text(render(d), "#{form_id}-refusal") =~ "This draft was published earlier"

    # A deleted publication can't be compared, so it clears nothing either.
    {:ok, _receipt} = Content.delete_content(Scope.for_user(user), :tip, id)
    html = b |> form(form_id, tip: values) |> render_submit()
    refute_push_event(b, "editor:clear", _)
    assert text(html, "#{form_id}-refusal") =~ "This draft was published earlier"
    refute has?(html, "#{form_id}-refusal a")
  end

  test "a lost reply is looked up after the reconnect; a lost sign-in fixes the values", %{
    conn: conn,
    user: user
  } do
    form_id = "#editor-#{user.id}-tip"
    values = %{"title" => "Plan first", "body" => "Plan before you prompt.", "tag_id" => "other"}
    {:ok, _lv, before} = live(conn, "/editor/tips/new")
    key = record(before, form_id)["submission_key"]

    # The publish committed, but its reply was lost with the connection.
    attrs = Map.merge(record(before, form_id)["intent"]["attrs"], values)
    {:ok, _receipt} = Content.publish_tip(Scope.for_user(user), key, atoms(attrs), [])

    {:ok, lv, fresh} = live(conn, "/editor/tips/new")
    recover(lv, fresh, form_id, before, values)
    render_hook(lv, "editor:reconcile", %{})
    assert_push_event(lv, "editor:clear", %{draft_id: ^key})
    assert_push_event(lv, "editor:settled", %{unresolved: false})

    # Another draft's lookup finds the sign-in expired: its values stay fixed.
    {:ok, lv, _html} = live(conn, "/editor/tips/new")
    lv |> form(form_id, tip: values) |> render_change()
    Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)
    html = render_hook(lv, "editor:reconcile", %{})

    assert_push_event(lv, "editor:settled", %{unresolved: true})
    assert text(html, "#{form_id}-refusal") =~ "your sign-in has expired"
    assert has?(html, "#{form_id}-refusal a[href^='/users/log-in']")
    assert has?(html, "fieldset[disabled] #tip_body")
    assert has?(html, "button[type=submit][disabled]")
    assert record(html, form_id)["intent"]["attrs"]["body"] == "Plan before you prompt."
  end

  test "a lost edit reply shows the saved version beside the proposal and keeps the version",
       %{conn: conn, user: user} do
    review = review_fixture(tip_fixture(), %{user_id: user.id, body: "Saved body"})
    path = "/editor/reviews/#{review.id}/edit"
    form_id = "#editor-#{user.id}-review"
    {:ok, _lv, before} = live(conn, path)
    attrs = atoms(record(before, form_id)["intent"]["attrs"])

    # Another save landed first; this page's reply was lost.
    {:ok, %{edit_version: 2}} =
      Content.edit_review(
        Scope.for_user(user),
        review.id,
        1,
        %{attrs | body: "Saved elsewhere"},
        []
      )

    {:ok, lv, fresh} = live(conn, path)
    recover(lv, fresh, form_id, before, %{"body" => "My proposal"})
    html = render_hook(lv, "editor:reconcile", %{})

    refute_push_event(lv, "editor:clear", _)
    assert text(html, "#{form_id}-saved dd") == "Saved elsewhere"

    assert text(html, "#{form_id}-refusal") =~
             "We couldn't confirm whether your changes were saved"

    assert textarea(html, "review[body]") == "My proposal"
    assert record(html, form_id)["expected_version"] == 1

    # Saving again is explicit and keeps the version guard.
    html = lv |> form(form_id, review: %{body: "My proposal"}) |> render_submit()
    assert text(html, "#{form_id}-refusal") =~ "This review changed after you opened it"
    assert %Review{body: "Saved elsewhere", edit_version: 2} = Repo.get!(Review, review.id)
  end

  describe "image selection" do
    test "a refused publish keeps the selected file; the corrected publish consumes it",
         %{conn: conn, user: user} do
      R2Stub.record()
      form_id = "#editor-#{user.id}-tip"
      {:ok, lv, _html} = live(conn, "/editor/tips/new")
      Req.Test.allow(R2, self(), lv.pid)
      select_image(lv, form_id)

      values = %{title: "", body: "Plan before you prompt.", tag_id: "other"}
      html = lv |> form(form_id, tip: values) |> render_submit()

      assert_push_event(lv, "editor:refused", %{})
      assert summary_links(html, form_id) == ["#tip_title"]
      assert [_ref] = done_refs(html)
      assert R2Stub.requests() == []

      lv |> form(form_id, tip: %{values | title: "Plan first"}) |> render_submit()

      assert_push_event(lv, "editor:clear", %{})
      assert [{"PUT", key}] = R2Stub.requests()
      assert %Tip{id: id} = Repo.get_by!(Tip, title: "Plan first")
      assert [%Asset{tip_id: ^id, key: ^key, position: 0}] = Repo.all(Asset)
      assert_consumed(lv)
    end

    test "a review refused after storing keeps its file; the retry stores it anew",
         %{conn: conn, user: user} do
      R2Stub.record()
      tip = tip_fixture(user_fixture())
      form_id = "#editor-#{user.id}-review"
      {:ok, lv, html} = live(conn, "/editor/tips/#{tip.id}/reviews/new")
      Req.Test.allow(R2, self(), lv.pid)
      key = record(html, form_id)["submission_key"]
      select_image(lv, form_id)

      # A moderator hides the tip after the page loaded.
      Repo.update_all(from(t in Tip, where: t.id == ^tip.id), set: [dead_at: DateTime.utc_now()])
      html = lv |> form(form_id, review: %{body: "Worked on a rename."}) |> render_submit()

      assert text(html, "#{form_id}-refusal") =~ "This tip is no longer open for reviews."
      assert [_ref] = done_refs(html)
      assert [{"PUT", first}, {"DELETE", deleted}] = R2Stub.requests()
      assert deleted == first

      Repo.update_all(from(t in Tip, where: t.id == ^tip.id), set: [dead_at: nil])
      lv |> form(form_id, review: %{body: "Worked on a rename."}) |> render_submit()

      assert_push_event(lv, "editor:clear", %{draft_id: ^key})
      assert [{"PUT", second}] = R2Stub.requests()
      refute second == first
      assert %Review{id: id} = Repo.get_by!(Review, submission_key: key)
      assert [%Asset{review_id: ^id, key: ^second}] = Repo.all(Asset)
      assert_consumed(lv)
    end

    test "a restored image slot must be selected again and keeps its description",
         %{conn: conn, user: user} do
      R2Stub.record()
      form_id = "#editor-#{user.id}-tip"
      {:ok, lv, html} = live(conn, "/editor/tips/new")
      Req.Test.allow(R2, self(), lv.pid)

      slot = %{
        "tag" => "missing_image",
        "slot" => "s1",
        "filename" => "plan.png",
        "type" => "image/png",
        "size" => 2048,
        "description" => "The plan in the terminal"
      }

      saved =
        html
        |> record(form_id)
        |> put_in(["intent", "uploads"], [slot])
        |> put_in(["intent", "attrs"], %{
          "title" => "Plan first",
          "body" => "Plan before you prompt.",
          "tag_id" => "other"
        })

      render_hook(lv, "editor:restore", %{
        "identity" => identity(html, form_id),
        "record" => saved
      })

      assert_reply(lv, %{status: "restored"})

      html = lv |> form(form_id) |> render_submit()

      assert_push_event(lv, "editor:refused", %{})
      assert text(html, "#{form_id}-errors") =~ "Attachments: must be selected again"
      assert text(html, "#{form_id}-evidence-image-s1") =~ "plan.png must be selected again."
      assert R2Stub.requests() == []

      select_image(lv, form_id)
      assert [%{"slot" => "s1"}] = record(render(lv), form_id)["intent"]["uploads"]
      lv |> form(form_id) |> render_submit()

      assert_push_event(lv, "editor:clear", %{})
      assert [{"PUT", key}] = R2Stub.requests()
      assert [%Asset{key: ^key, description: "The plan in the terminal"}] = Repo.all(Asset)
    end

    test "an edit removes a saved image and saves its replacement, or saves the removal alone",
         %{conn: conn, user: user} do
      R2Stub.record()
      form_id = "#editor-#{user.id}-tip"

      for replace? <- [true, false] do
        tip = tip_fixture(user)
        saved = image_fixture(tip, position: 0)
        {:ok, lv, _html} = live(conn, "/editor/tips/#{tip.id}/edit")
        Req.Test.allow(R2, self(), lv.pid)

        lv
        |> element("#{form_id}-evidence-media-#{saved.id} button", "Remove")
        |> render_click()

        if replace?, do: select_image(lv, form_id)
        lv |> form(form_id) |> render_submit()

        assert_push_event(lv, "editor:clear", %{})
        assert %Tip{edit_version: 2} = Repo.get!(Tip, tip.id)
        assert %Asset{cleanup_at: %DateTime{}, position: nil} = Repo.reload!(saved)
        assert_enqueued(worker: CleanupMedia, args: %{media_id: saved.id})
        attached = Repo.all(from(a in Asset, where: a.tip_id == ^tip.id and is_nil(a.cleanup_at)))

        if replace? do
          assert [{"PUT", key}] = R2Stub.requests()
          assert [%Asset{key: ^key, position: 0}] = attached
        else
          assert R2Stub.requests() == []
          assert attached == []
        end
      end
    end

    test "a lost reply with an image is published earlier; the file stays selected",
         %{conn: conn, user: user} do
      R2Stub.record()
      form_id = "#editor-#{user.id}-tip"

      values = %{
        "title" => "Plan first",
        "body" => "Plan before you prompt.",
        "tag_id" => "other"
      }

      {:ok, lv, html} = live(conn, "/editor/tips/new")
      key = record(html, form_id)["submission_key"]
      select_image(lv, form_id)
      lv |> form(form_id, tip: values) |> render_change()

      # The publish committed with this file, but its reply was lost.
      attrs = atoms(Map.merge(record(html, form_id)["intent"]["attrs"], values))
      image = %{path: @png, filename: "plan.png"}

      {:ok, %{outcome: :created}} =
        Content.publish_tip(Scope.for_user(user), key, attrs, [{:image_file, "s1", image, nil}])

      html = render_hook(lv, "editor:reconcile", %{})

      refute_push_event(lv, "editor:clear", _)
      assert text(html, "#{form_id}-refusal") =~ "This draft was published earlier"
      # A consumed entry leaves on its upload process's report, which is queued
      # during the event and handled before the next render.
      assert [_ref] = done_refs(render(lv))
      assert [{"PUT", stored}] = R2Stub.requests()
      assert [%Asset{key: ^stored}] = Repo.all(Asset)
    end
  end

  test "a file whose upload could not be written shows its error beside its slot" do
    entry = %UploadEntry{
      ref: "0",
      upload_ref: "phx-images",
      upload_config: :images,
      client_name: "plan.png",
      client_size: 2048,
      client_type: "image/png"
    }

    upload = %UploadConfig{
      name: :images,
      ref: "phx-images",
      entries: [entry],
      errors: [{"0", {:writer_failure, :enospc}}]
    }

    html =
      render_component(&Editor.evidence_fields/1,
        form: Phoenix.Component.to_form(%{}, as: :tip),
        id: "evidence",
        upload: upload,
        selection: [{:missing_image, "s1", %{filename: "plan.png", size: 2048, description: nil}}],
        images: %{"s1" => "0"},
        attached: %{},
        video_upload: %UploadConfig{name: :videos, ref: "phx-videos"},
        video_states: %{},
        video_refs: %{}
      )

    assert text(html, "#evidence-image-s1") =~
             "plan.png could not be uploaded. Remove it and select it again."
  end

  defp select_image(lv, form_id) do
    lv
    |> file_input(form_id, :images, [
      %{name: "plan.png", content: File.read!(@png), type: "image/png"}
    ])
    |> render_upload("plan.png")
  end

  defp done_refs(html) do
    case html
         |> find("input[type=file][name=images]")
         |> LazyHTML.attribute("data-phx-done-refs") do
      [""] -> []
      [refs] -> String.split(refs, ",")
    end
  end

  # Consumed entries leave the page once their upload processes stop.
  defp assert_consumed(lv, attempts \\ 50) do
    cond do
      done_refs(render(lv)) == [] ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        assert_consumed(lv, attempts - 1)

      true ->
        flunk("the selected file was not consumed")
    end
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

  defp json(values), do: Map.new(values, fn {field, value} -> {Atom.to_string(field), value} end)

  defp atoms(attrs),
    do: Map.new(attrs, fn {field, value} -> {String.to_existing_atom(field), value} end)

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
