defmodule TipsWeb.EditorPublishTest do
  @moduledoc """
  Real-browser test of a confirmed publish with an image (#82): a selection
  patch that lands after Publish does not keep the hook from clearing the
  submitted draft. The page's LiveView process is not a caller of this test,
  so the R2 stub is shared, which requires async: false.
  """
  use Tips.FeatureCase, async: false

  import Tips.AccountsFixtures

  alias Tips.Content.Media.Asset
  alias Tips.R2Stub
  alias Tips.Repo

  @moduletag :browser

  @png Path.expand("../../fixtures/images/static.png", __DIR__)

  setup %{session: session} do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    # The image is stored for longer than the hook's save delay.
    R2Stub.record(fn _method, _key ->
      Process.sleep(1000)
      200
    end)

    sign_in(session, user_fixture())
    :ok
  end

  feature "a description patched in after Publish still clears the published draft",
          %{session: session} do
    session
    |> visit("/editor/tips/new")
    |> assert_has(css(".phx-connected"))
    |> fill_in(text_field("Title"), with: "Plan first")
    |> fill_in(text_field("Tip"), with: "Plan before you prompt.")
    |> click(css("#tip_tag_id option[value='other']"))
    |> click(css("summary", text: "Prompt and result"))
    |> attach_file(file_field("Add an image (optional)"), path: @png)
    |> assert_has(css("li", text: "static.png"))

    # The description's patch arrives only after the submit began.
    hold_frames(session)
    fill_in(session, text_field("Image description (optional)"), with: "The plan")
    await_held(session, "phx_reply")
    click(session, button("Publish"))
    release_frames(session)

    assert_has(session, css("h1", text: "Plan first"))
    assert [%Asset{description: "The plan"}] = Repo.all(Asset)
  end
end
