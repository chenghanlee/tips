defmodule TipsWeb.BrowseFeatureTest do
  use Tips.FeatureCase, async: true

  import Tips.ContentFixtures, only: [tip_fixture: 2]

  @moduletag :browser

  setup do
    author = Tips.AccountsFixtures.user_fixture()
    for n <- 1..21, do: tip_fixture(author, %{title: "Flake fix #{n}", tag_id: "workflow"})
    :ok
  end

  feature "select changes keep focus and reset the page; Clear filters keeps the sort",
          %{session: session} do
    session
    |> visit("/?page=2")
    |> assert_has(css(".phx-connected"))
    |> assert_has(css("#tip-rows li", count: 1))
    |> choose_focused("sort", "new")
    |> assert_has(css("#feed-heading", text: "New tips"))
    |> assert_has(css("#tip-rows li", count: 20))
    |> assert_focus("sort")
    |> then(&assert(current_url(&1) =~ ~r{/\?sort=new$}))
    |> choose_focused("environment", "cli")
    |> assert_has(css("#tips-empty", text: "No tips match these filters"))
    |> assert_focus("environment")
    |> click(link("Clear filters"))
    |> assert_has(css("#tip-rows li", count: 20))
    |> then(&assert(current_url(&1) =~ ~r{/\?sort=new$}))
  end

  feature "Back restores the page URL and the reading position", %{session: session} do
    session
    |> visit("/")
    |> assert_has(css(".phx-connected"))
    |> assert_has(css("#tip-rows li", count: 20))

    bottom = scroll_to_bottom(session)
    assert bottom > 0

    session
    |> click(css("a[rel=next]"))
    |> assert_has(css("#feed-heading", text: "Page 2"))
    |> js("history.back()")
    |> assert_has(css("#tip-rows li", count: 20))
    |> refute_has(css("#feed-heading", text: "Page 2"))
    |> assert_scroll(bottom)

    # Back from a tip mounts the feed again.
    session
    |> click(css("#tip-rows li:last-child a[href^='/tips/']"))
    |> refute_has(css("#feed"))
    |> js("history.back()")
    |> assert_has(css("#tip-rows li", count: 20))
    |> assert_scroll(bottom)
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

  defp script_value(session, script) do
    execute_script(session, script, [], &send(self(), {:script_value, &1}))
    assert_received {:script_value, value}
    value
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
