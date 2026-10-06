defmodule TipsWeb.EditorReconcileTest do
  @moduledoc """
  Real-browser tests of publication and edit acknowledgements (#80): two tabs
  sharing one draft, and a publish or save whose reply is lost with the
  connection. The test drops the page's `phx_reply` frames, waits for the
  write to commit, then reconnects.
  """
  use Tips.FeatureCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Content.Tip
  alias Tips.Repo

  @moduletag :browser

  @store_source Path.expand("../../../assets/js/editor_draft_store.js", __DIR__)

  setup %{session: session} do
    user = user_fixture()
    sign_in(session, user)
    %{user: user, form: "#editor-#{user.id}-tip"}
  end

  feature "a tab whose draft has newer work in another tab publishes and stays; the newer draft stays",
          %{session: session, form: form} do
    tab_a = window_handle(session)
    session |> open_editor("/editor/tips/new") |> compose("Plan before you prompt.", form)
    storage = hidden_record(session)["storage"]

    tab_b = open_tab(session)

    session
    |> open_editor("/editor/tips/new")
    |> assert_has(css("#{form}-status", text: "Recovered your draft from this browser."))
    |> fill_in(text_field("Tip"), with: "Plan before you prompt, then test.")
    |> assert_has(css("#{form}-status", text: "Draft saved in this browser at"))

    session
    |> focus_window(tab_a)
    |> click(button("Publish"))
    |> assert_has(
      css("#{form}-outcome", text: "A different draft saved in this browser was kept")
    )

    assert current_path(session) == "/editor/tips/new"

    assert %{"intent" => %{"attrs" => %{"body" => "Plan before you prompt, then test."}}} =
             stored(session, storage)

    session
    |> focus_window(tab_b)
    |> click(button("Publish"))
    |> assert_has(css("#{form}-refusal", text: "This draft was published earlier"))

    assert field_value(session, "#tip_body") == "Plan before you prompt, then test."
    assert [%Tip{body: "Plan before you prompt."}] = Repo.all(Tip)
  end

  feature "a publish whose replies were lost is looked up after the reconnect, cleared and left",
          %{session: session, form: form} do
    session |> open_editor("/editor/tips/new") |> compose("Plan before you prompt.", form)
    %{"storage" => storage, "submission_key" => key} = hidden_record(session)

    drop_replies(session)
    click(session, button("Publish"))
    await(fn -> Repo.get_by(Tip, submission_key: key) end)

    # The lookup confirms it and the hook clears the draft, but its report
    # never reaches the page.
    drop_push(session, "editor:cleared")
    reconnect(session)
    await_cleared(session, storage)
    reconnect(session)

    assert_has(session, css("h1", text: "Plan first"))
  end

  feature "a save whose reply was lost shows the saved version beside the proposal",
          %{session: session, user: user, form: form} do
    tip = tip_fixture(user, %{title: "Plan first", body: "Saved body"})
    open_editor(session, "/editor/tips/#{tip.id}/edit")
    fill_in(session, text_field("Tip"), with: "Edited body")

    drop_replies(session)
    click(session, button("Save changes"))
    await(fn -> Repo.get_by(Tip, id: tip.id, edit_version: 2) end)
    reconnect(session)

    session
    |> assert_has(
      css("#{form}-refusal", text: "We couldn't confirm whether your changes were saved")
    )
    |> assert_has(css("#{form}-saved", text: "Edited body"))

    assert field_value(session, "#tip_body") == "Edited body"
    assert hidden_record(session)["expected_version"] == 1
  end

  defp sign_in(session, user) do
    {token, _hashed} = generate_user_magic_link_token(user)

    session
    |> visit("/users/log-in/#{token}")
    |> click(button("Log me in only this time"))
    |> assert_has(css("header", text: user.email))
  end

  defp open_editor(session, path) do
    session
    |> visit(path)
    |> assert_has(css(".phx-connected"))
  end

  defp compose(session, body, form) do
    session
    |> fill_in(text_field("Title"), with: "Plan first")
    |> click(option("Other technique"))
    |> fill_in(text_field("Tip"), with: body)
    |> assert_has(css("#{form}-status", text: "Draft saved in this browser at"))
  end

  # Drops every reply frame from the server, as a lost connection would,
  # until `reconnect/1`.
  defp drop_replies(session) do
    run(session, """
    const socket = window.liveSocket.getSocket()
    const receive = socket.onConnMessage.bind(socket)
    window.dropReplies = true
    socket.onConnMessage = (event) => {
      if (window.dropReplies && JSON.parse(event.data)[3] === "phx_reply") return
      receive(event)
    }
    """)
  end

  # Never sends the page's `event` pushes.
  defp drop_push(session, event) do
    run(
      session,
      """
      const socket = window.liveSocket.getSocket()
      const push = socket.push.bind(socket)
      socket.push = (data) => {
        if (data.payload?.event !== args[0]) push(data)
      }
      """,
      [event]
    )
  end

  # Returns once `connect()` is called; the page may then leave.
  defp reconnect(session) do
    run(session, """
    const main = document.querySelector("[data-phx-main]")
    const until = async (test) => { while (!test()) await new Promise((r) => setTimeout(r, 50)) }
    window.liveSocket.disconnect()
    await until(() => !main.classList.contains("phx-connected"))
    window.dropReplies = false
    window.liveSocket.connect()
    """)
  end

  defp await(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 1 ->
        Process.sleep(50)
        await(fun, tries - 1)

      nil ->
        flunk("the write did not commit")

      found ->
        found
    end
  end

  defp await_cleared(session, storage) do
    run(
      session,
      """
      const store = await importStore()
      const deadline = Date.now() + 5000
      while ((await store.load(args[0])).record !== null) {
        if (Date.now() > deadline) throw new Error("the draft was not cleared")
        await new Promise((resolve) => setTimeout(resolve, 50))
      }
      """,
      [storage]
    )
  end

  defp stored(session, storage) do
    %{"status" => "ok", "record" => record} =
      run(session, "return (await importStore()).load(args[0])", [storage])

    record
  end

  defp hidden_record(session) do
    run(session, ~s|return JSON.parse(document.querySelector("[name='editor[record]']").value)|)
  end

  defp field_value(session, selector),
    do: run(session, "return document.querySelector(args[0]).value", [selector])

  defp open_tab(session) do
    tabs = window_handles(session)
    execute_script(session, "window.open('about:blank', '_blank')")
    [tab] = window_handles(session) -- tabs
    focus_window(session, tab)
    tab
  end

  # Runs an async script body with `args` and `importStore()`, which imports
  # the production draft store. JS errors fail the test.
  defp run(session, body, args \\ []) do
    script = """
    const done = arguments[arguments.length - 1]
    const [source, ...args] = Array.from(arguments).slice(0, -1)
    const importStore = async () => {
      const url = URL.createObjectURL(new Blob([source], {type: "text/javascript"}))
      try {
        return await import(url)
      } finally {
        URL.revokeObjectURL(url)
      }
    }
    ;(async () => {
    #{body}
    })().then(
      (value) => done({ok: value ?? null}),
      (error) => done({error: String(error?.stack ?? error)}),
    )
    """

    case Wallaby.WebdriverClient.execute_script_async(session, script, [
           File.read!(@store_source) | args
         ]) do
      {:ok, %{"ok" => value}} -> value
      {:ok, %{"error" => error}} -> flunk("browser script failed:\n" <> error)
    end
  end
end
