defmodule Tips.FeatureHelpers do
  @moduledoc "Browser steps shared by the feature tests through `Tips.FeatureCase`."

  import ExUnit.Assertions
  import Wallaby.Browser, only: [current_url: 1, execute_script: 3, execute_script: 4]

  @doc """
  Selects `value` with the control focused, as a reader does. WebDriver's
  option click does not reliably focus the select in headless Chrome.
  """
  def choose_focused(session, id, value) do
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

  @doc "Asserts that the current URL matches `pattern`."
  def assert_url(session, pattern) do
    assert current_url(session) =~ pattern
    session
  end

  @doc "Asserts that the element with `id` has focus."
  def assert_focus(session, id) do
    execute_script(session, "return document.activeElement.id", [], &assert(&1 == id))
  end
end
