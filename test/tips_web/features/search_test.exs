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

  feature "initial HTML shows results; blank search and filter changes keep focus and the draft",
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
    |> fill_in(css("#q"), with: "draft terms")
    |> click(link("Other technique"))
    |> assert_has(css("#results-heading", text: "Technique: Other technique"))
    |> assert_draft("draft terms")
    |> choose_focused("technique", "persona")
    |> assert_has(css("#results-empty", text: "No tips match these filters"))
    |> assert_focus("technique")
    |> assert_draft("draft terms")
    |> then(&assert(current_url(&1) =~ "/search?q=flake&technique=persona"))
  end

  feature "Back, reconnect and Retry keep the URL's page and the reading position",
          %{session: session} do
    author = Tips.AccountsFixtures.user_fixture()
    for n <- 1..20, do: indexed_tip!(author, %{title: "Flake fix #{n}"})

    session
    |> visit("/search?q=flake")
    |> assert_has(css(".phx-connected"))
    |> assert_has(css("#result-rows li", count: 20))

    bottom = scroll_to_bottom(session)
    assert bottom > 0

    # Page 2 loads after the patch; Back restores page 1 where the reader was.
    session
    |> click(css("a[rel=next]"))
    |> assert_has(css("#results-heading", text: "Page 2"))
    |> js("history.back()")
    |> assert_has(css("#result-rows li", count: 20))
    |> refute_has(css("#results-heading", text: "Page 2"))
    |> assert_scroll(bottom)

    # Back from a tip mounts the search page again.
    tip = "#result-rows li:last-child a[href^='/tips/']"

    title =
      script_value(session, "return document.querySelector(arguments[0]).textContent.trim()", [
        tip
      ])

    session
    |> click(css(tip))
    |> refute_has(css("#results"))
    |> assert_has(css("h1", text: title))
    |> js("history.back()")
    |> assert_has(css("#result-rows li", count: 20))
    |> assert_scroll(bottom)

    session
    |> click(css("a[rel=next]"))
    |> assert_has(css("#results-heading", text: "Page 2"))
    |> js("liveSocket.disconnect()")
    |> assert_has(css(".phx-client-error"))
    |> js("liveSocket.connect()")
    |> assert_has(css(".phx-connected"))
    |> assert_has(css("#results-heading", text: "Page 2"))
    |> assert_has(css("#result-rows li", count: 1))

    # The search relations become unresolvable until the path is restored.
    Tips.Repo.query!("SET LOCAL search_path = pg_catalog")
    choose_focused(session, "environment", "cli")
    assert_has(session, css("#results-error", text: "Couldn't load this page of results."))
    Tips.Repo.query!("SET LOCAL search_path TO DEFAULT")

    history = script_value(session, "return history.length")

    session
    |> click(button("Retry"))
    |> assert_has(css("#results-empty", text: "No tips match these filters"))
    |> then(&assert(current_url(&1) =~ "/search?environment=cli&q=flake"))
    |> then(&assert(script_value(&1, "return history.length") == history))
  end

  defp scroll_to_bottom(session) do
    bottom =
      script_value(
        session,
        "window.scrollTo(0, document.body.scrollHeight); return window.scrollY"
      )

    # LiveView saves the position in the history entry after scrolling settles.
    eventually(fn -> script_value(session, "return history.state.scroll") == bottom end)
    bottom
  end

  defp assert_scroll(session, y) do
    eventually(fn -> abs(script_value(session, "return window.scrollY") - y) <= 2 end)
    session
  end

  defp eventually(check, tries \\ 40) do
    cond do
      check.() ->
        :ok

      tries == 1 ->
        flunk("condition not met")

      true ->
        Process.sleep(50)
        eventually(check, tries - 1)
    end
  end

  defp js(session, script), do: execute_script(session, script)

  defp script_value(session, script, args \\ []) do
    execute_script(session, script, args, &send(self(), {:script_value, &1}))
    assert_received {:script_value, value}
    value
  end

  defp assert_draft(session, text) do
    execute_script(session, "return document.getElementById('q').value", [], &assert(&1 == text))
  end

  # Selects with the control focused, as a reader does. WebDriver's option
  # click does not reliably focus the select in headless Chrome.
  defp choose_focused(session, id, value) do
    execute_script(
      session,
      """
      const select = document.getElementById(arguments[0]);
      select.focus();
      select.value = arguments[1];
      select.dispatchEvent(new Event("input", {bubbles: true}));
      select.dispatchEvent(new Event("change", {bubbles: true}));
      """,
      [id, value]
    )
  end

  defp assert_focus(session, id) do
    execute_script(session, "return document.activeElement.id", [], &assert(&1 == id))
  end
end
