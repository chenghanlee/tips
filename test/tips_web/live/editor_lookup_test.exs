defmodule TipsWeb.EditorLookupTest do
  @moduledoc """
  Acceptance evidence for #80: an unknown publish outcome is looked up once,
  a failed lookup stays unresolved with fixed values, and an absent
  publication is retried explicitly with the same key and values.
  """
  # The test renames the tips table inside its sandbox transaction, so the
  # rename rolls back with the test. The rename locks the table until then,
  # so this module runs alone.
  use TipsWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import TipsWeb.ReaderPageHelpers

  alias Tips.Content.Tip
  alias Tips.Repo

  setup :register_and_log_in_user

  test "a failed lookup keeps the values fixed until Check again finds nothing to retry", %{
    conn: conn,
    user: user
  } do
    form_id = "#editor-#{user.id}-tip"
    {:ok, lv, html} = live(conn, "/editor/tips/new")
    key = JSON.decode!(hidden(html, "editor[record]"))["submission_key"]
    values = %{title: "Plan first", body: "Plan before you prompt.", tag_id: "other"}

    # The database fails both the publish and its lookup.
    Repo.query!("ALTER TABLE tips RENAME TO tips_unavailable")

    html =
      capture_log_html(fn -> lv |> form(form_id, tip: values) |> render_submit() end)

    assert text(html, "#{form_id}-refusal") =~ "We couldn't check whether this was published"
    assert has?(html, "fieldset[disabled] #tip_body")
    assert has?(html, "button[type=submit][disabled]")
    assert_push_event(lv, "editor:settled", %{unresolved: true})
    refute_push_event(lv, "editor:clear", _)

    Repo.query!("ALTER TABLE tips_unavailable RENAME TO tips")
    html = render_click(lv, "editor:reconcile", %{})

    assert text(html, "#{form_id}-refusal") =~ "it isn't published now"
    assert text(html, "button[type=submit]") == "Retry"
    assert has?(html, "fieldset[disabled] #tip_body")
    refute Repo.exists?(Tip)

    # Retry sends the same key and the submitted values, whatever the form sends.
    lv |> element(form_id) |> render_submit(%{tip: %{body: "Changed"}})
    assert_push_event(lv, "editor:clear", %{draft_id: ^key})
    assert %Tip{body: "Plan before you prompt."} = Repo.get_by!(Tip, submission_key: key)
  end

  defp capture_log_html(fun) do
    parent = self()
    log = capture_log(fn -> send(parent, {:html, fun.()}) end)
    assert log =~ "Publication outcome unknown"
    assert_received {:html, html}
    html
  end

  defp hidden(html, name),
    do: html |> find(~s(input[name="#{name}"])) |> LazyHTML.attribute("value") |> hd()
end
