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
    |> send_keys([:tab])
    |> js(
      """
      const style = getComputedStyle(document.activeElement);
      document.getElementById("fixture_body").focus();
      const input = getComputedStyle(document.activeElement);
      return [style.outlineWidth, style.outlineStyle, input.outlineWidth, input.outlineStyle];
      """,
      fn outlines -> assert outlines == ["2px", "solid", "2px", "solid"] end
    )
  end

  feature "a filter change patches the URL and keeps focus; Clear filters keeps the query", %{
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
    |> js("return document.activeElement.id", &assert(&1 == "technique"))
    |> click(link("Clear filters"))
    |> assert_has(css("#applied", text: "q=flaky"))
    |> refute_has(link("Clear filters"))
    |> js("return document.getElementById('technique').value", &assert(&1 == ""))
  end

  feature "an open disclosure stays open while a vote patches the page", %{session: session} do
    session
    |> connected("/_ui")
    |> click(css("#evidence summary"))
    |> click(css("#vote-tip button", text: "Not helpful"))
    |> assert_has(css("#vote-tip button[aria-disabled=true]", count: 2))
    |> assert_has(css("#vote-tip [role=status]", text: "Saving"))
    |> js("return document.activeElement.textContent.trim()", &assert(&1 == "Not helpful"))
    |> assert_has(css("#vote-tip button[aria-pressed=true]", text: "Not helpful"))
    |> refute_has(css("#vote-tip button[aria-disabled=true]"))
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
    |> js("return document.activeElement.id", &assert(&1 == "q"))
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
