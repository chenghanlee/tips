defmodule TipsWeb.UIComponentsTest do
  use Tips.FeatureCase, async: true

  @moduletag :browser

  defp connected(session, path) do
    session
    |> resize_window(1280, 800)
    |> visit(path)
    |> assert_has(css(".phx-connected"))
  end

  defp js(session, script, check) do
    execute_script(session, script, [], check)
  end

  defp assert_focus(session, id) do
    js(
      session,
      "const el = document.activeElement; return [el.id, `${el.tagName}#${el.id}.${el.className}`]",
      fn [active_id, element] -> assert active_id == id, "focus is on #{element}" end
    )
  end

  feature "built assets carry the Tips baseline", %{session: session} do
    session
    |> connected("/_ui")
    |> js(
      """
      const probe = document.createElement("div");
      probe.style.color = "var(--input)";
      document.body.appendChild(probe);
      const input = getComputedStyle(document.getElementById("fixture_body"));
      return [input.borderTopColor, getComputedStyle(probe).color, getComputedStyle(document.body).backgroundColor];
      """,
      fn [border, input_token, background] ->
        assert border == input_token
        assert background in ["rgb(255, 255, 255)", "oklch(1 0 0)"]
      end
    )
    # Script focus, not a Tab from <body>: headless Chrome in CI does not move
    # focus on a page-level Tab. The button follows a focus-visible input, so
    # it matches :focus-visible too.
    |> js(
      """
      const outline = (el) => {
        el.focus();
        const style = getComputedStyle(document.activeElement);
        return [style.outlineWidth, style.outlineStyle, describe(document.activeElement)];
      };
      const describe = (el) =>
        `${el.tagName}#${el.id}.${el.className} focus-visible=${el.matches(":focus-visible")}`;
      const search = [...document.querySelectorAll("button")].find(b => b.textContent.trim() === "Search");
      return [outline(document.getElementById("fixture_body")), outline(search)];
      """,
      fn [[input_width, input_style, input], [button_width, button_style, button]] ->
        assert {input_width, input_style} == {"2px", "solid"}, input
        assert {button_width, button_style} == {"2px", "solid"}, button
      end
    )
  end

  feature "filter changes keep focus; Clear filters keeps the query and focuses the note", %{
    session: session
  } do
    session
    |> connected("/_ui?q=flaky")
    |> js(
      """
      const select = document.getElementById("technique");
      select.focus();
      select.value = "planning";
      select.dispatchEvent(new Event("change", {bubbles: true}));
      """,
      fn _ -> :ok end
    )
    |> assert_has(css("#applied", text: "q=flaky&technique=planning"))
    |> assert_focus("technique")
    |> assert_has(css("#filters a[href='/_ui?q=flaky']", text: "Clear filters"))
    |> js("window.historyBefore = history.length", fn _ -> :ok end)
    |> click(link("Clear filters"))
    |> refute_has(link("Clear filters"))
    |> js(
      "return history.length - window.historyBefore",
      &assert(&1 == 1, "history entries added: #{&1}")
    )
    |> js("return document.getElementById('applied').textContent", &assert(&1 == "q=flaky"))
    |> assert_focus("filters-note")
    |> js("return document.getElementById('technique').value", &assert(&1 == ""))
  end

  feature "an open disclosure stays open while a vote patches the page", %{session: session} do
    session
    |> connected("/_ui")
    |> click(css("#evidence summary"))
    |> click(css("#tip-vote button", text: "Not helpful"))
    |> assert_has(css("#tip-vote button[aria-disabled=true]", count: 2))
    |> assert_has(css("#tip-vote [role=status]", text: "Saving"))
    |> js("return document.activeElement.textContent.trim()", &assert(&1 == "Not helpful"))
    |> assert_has(css("#tip-vote button[aria-pressed=true]", text: "Not helpful"))
    |> refute_has(css("#tip-vote button[aria-disabled=true]"))
    |> js("return document.getElementById('evidence').open", &assert(&1 == true))
  end

  feature "a blank search shows the message, keeps results and focuses the field", %{
    session: session
  } do
    session
    |> connected("/_ui?q=flaky")
    |> fill_in(css("#q"), with: "   ")
    |> click(button("Search"))
    |> assert_has(css("#q-error", text: "Enter a task or keywords to search."))
    |> assert_has(css("#applied", text: "q=flaky"))
    |> assert_has(css("#results", text: "Results for “flaky”"))
    |> assert_focus("q")
  end

  feature "reconnect renders the URL-driven select values", %{session: session} do
    session
    |> connected("/_ui?technique=planning&environment=claude-code")
    |> js("liveSocket.disconnect()", fn _ -> :ok end)
    |> refute_has(css(".phx-connected"))
    |> js("liveSocket.connect()", fn _ -> :ok end)
    |> assert_has(css(".phx-connected"))
    |> js(
      "return ['technique', 'model', 'environment'].map(id => document.getElementById(id).value)",
      &assert(&1 == ["planning", "", "claude-code"])
    )
  end
end
