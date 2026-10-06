defmodule TipsWeb.SearchFeatureTest do
  # The browser's LiveView process is not a caller of this test, so the
  # embedding stub is shared, which requires async: false.
  use Tips.FeatureCase, async: false

  import Tips.SearchFixtures, only: [indexed_tip!: 2]

  @moduletag :browser
  @moduletag :capture_log

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    Req.Test.stub(Tips.Content.Search.EmbeddingProvider, &Plug.Conn.send_resp(&1, 503, ""))
    indexed_tip!(Tips.AccountsFixtures.user_fixture(), %{title: "Reproduce the flake first"})
    :ok
  end

  feature "initial HTML shows results; blank search and filter changes keep focus",
          %{session: session} do
    session
    |> visit("/search?q=flake")
    |> assert_has(css("#result-rows li a", text: "Reproduce the flake first"))
    |> assert_has(css(".phx-connected"))
    |> fill_in(css("#q"), with: "   ")
    |> click(button("Search"))
    |> assert_has(css("#q-error", text: "Enter a task or keywords to search."))
    |> assert_has(css("#result-rows li a", text: "Reproduce the flake first"))
    |> assert_focus("q")
    |> click(css("#technique option[value=persona]"))
    |> assert_has(css("#results-empty", text: "No tips match these filters"))
    |> assert_focus("technique")
    |> then(&assert(current_url(&1) =~ "/search?q=flake&technique=persona"))
  end

  defp assert_focus(session, id) do
    execute_script(session, "return document.activeElement.id", [], &assert(&1 == id))
  end
end
