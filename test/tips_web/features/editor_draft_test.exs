defmodule TipsWeb.EditorDraftTest do
  @moduledoc """
  Real-browser tests of the editors' `EditorDraft` hook (#78): restore into a
  pristine form, typing before the hook mounts and during a slow storage read,
  reconnect recovery without a storage read, and storage failure.

  Drafts are seeded with the production store, imported through a Blob URL as
  in `TipsWeb.EditorDraftStoreTest`. LiveView's latency simulator holds the
  join so the test can type before the hook mounts. A second tab holds a real
  readwrite transaction to delay the hook's read.
  """
  use Tips.FeatureCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Wallaby.WebdriverClient

  @moduletag :browser

  @store_source Path.expand("../../../assets/js/editor_draft_store.js", __DIR__)
  @paused "Autosave is paused so it doesn't replace a draft saved earlier in this browser."

  setup %{session: session} do
    user = user_fixture()
    sign_in(session, user)
    %{user: user, status: "#editor-#{user.id}-tip-status"}
  end

  feature "a saved draft restores into a pristine form and autosave continues under its pair",
          %{session: session, status: status} do
    seeded = session |> open_editor("/editor/tips/new") |> seed("Saved title", "Saved body")

    session
    |> open_editor("/editor/tips/new")
    |> assert_has(css(status, text: "Recovered your draft from this browser."))
    |> assert_value("#tip_title", "Saved title")
    |> assert_value("#tip_body", "Saved body")

    assert hidden_record(session)["submission_key"] == seeded["submission_key"]

    session
    |> fill_in(text_field("Tip"), with: "Saved body, then more")
    |> assert_has(css(status, text: "Draft saved in this browser at"))

    assert %{"draft" => %{"draft_id" => draft_id, "revision" => revision}} =
             saved(session, seeded["storage"], "Saved body, then more")

    assert draft_id == seeded["draft"]["draft_id"] and revision > 0
  end

  feature "typing before the hook mounts stays until the author reloads the saved draft",
          %{session: session, status: status} do
    seeded = session |> open_editor("/editor/tips/new") |> seed("Saved title", "Saved body")

    run(session, "window.liveSocket.enableLatencySim(1000)")
    visit(session, "/editor/tips/new")

    assert run(
             session,
             "return document.querySelector('[data-phx-main].phx-connected') === null"
           ),
           "the page joined before the test typed"

    session
    |> fill_in(text_field("Tip"), with: "Typed before the page connected")
    |> assert_has(css(".phx-connected"))
    |> assert_has(css(status, text: @paused))

    run(session, "window.liveSocket.disableLatencySim()")
    assert_value(session, "#tip_body", "Typed before the page connected")
    assert stored(session, seeded["storage"]) == seeded

    # Typing while the reload reads storage stays too.
    editor_tab = window_handle(session)
    blocker_tab = open_tab(session)
    hold_store(session, blocker_tab)
    focus_window(session, editor_tab)
    click(session, button("Reload saved draft"))
    fill_in(session, text_field("Tip"), with: "Typed during the reload")
    release_store(session, blocker_tab)
    focus_window(session, editor_tab)
    settle_store(session)

    refute run(session, "return document.querySelector(\"fieldset[id$='-fields']\").disabled"),
           "the reload restored over the typing"

    session
    |> assert_has(css(status, text: @paused))
    |> assert_value("#tip_body", "Typed during the reload")
    |> click(button("Reload saved draft"))
    |> assert_has(css(status, text: "Recovered your draft from this browser."))
    |> assert_value("#tip_title", "Saved title")
    |> assert_value("#tip_body", "Saved body")
    |> refute_has(button("Reload saved draft"))

    assert hidden_record(session)["submission_key"] == seeded["submission_key"]
  end

  feature "typing during a slow storage read stays, and a read pending across a reconnect restores nothing",
          %{session: session, status: status} do
    seeded = session |> open_editor("/editor/tips/new") |> seed("Saved title", "Saved body")
    editor_tab = window_handle(session)
    blocker_tab = open_tab(session)

    # Typing while the read waits.
    hold_store(session, blocker_tab)
    focus_window(session, editor_tab)
    session |> open_editor("/editor/tips/new") |> assert_value("#tip_body", "")
    fill_in(session, text_field("Tip"), with: "Typed during the read")
    release_store(session, blocker_tab)
    focus_window(session, editor_tab)

    session
    |> assert_has(css(status, text: @paused))
    |> assert_value("#tip_body", "Typed during the read")

    # The read is still pending when the page has reconnected and recovered its form.
    hold_store(session, blocker_tab)
    focus_window(session, editor_tab)
    open_editor(session, "/editor/tips/new")
    recovered = hidden_record(session)

    reconnect(session)
    release_store(session, blocker_tab)
    focus_window(session, editor_tab)

    session
    |> assert_has(css(status, text: @paused))
    |> assert_value("#tip_title", "")
    |> assert_value("#tip_body", "")

    assert hidden_record(session)["submission_key"] == recovered["submission_key"]
    assert stored(session, seeded["storage"]) == seeded

    # A reload interrupted by a reconnect restores nothing; reloading again
    # applies the draft another tab saved in between.
    hold_store(session, blocker_tab)
    focus_window(session, editor_tab)
    count_reads(session)
    click(session, button("Reload saved draft"))
    await_reads(session, 1)
    reconnect(session)
    queue_save(session, blocker_tab, seeded, "Saved in another tab")
    focus_window(session, editor_tab)
    click(session, button("Reload saved draft"))
    await_reads(session, 2)
    release_store(session, blocker_tab)
    focus_window(session, editor_tab)

    session
    |> assert_has(css(status, text: "Recovered your draft from this browser."))
    |> assert_value("#tip_body", "Saved in another tab")
  end

  feature "reconnect recovers typed values and blanks without reading storage",
          %{session: session, user: user} do
    tip = tip_fixture(user_fixture(), %{model_id: "gpt", environment_id: "ide"})
    status = "#editor-#{user.id}-review-status"

    session
    |> open_editor("/editor/tips/#{tip.id}/reviews/new")
    |> assert_value("#review_model_id", "gpt")
    |> click(css("#review_model_id option[value='']"))
    |> fill_in(text_field("Review"), with: "Worked on a rename")
    |> assert_has(css(status, text: "Draft saved in this browser at"))

    before = hidden_record(session)
    %{"draft" => first_pair} = saved(session, before["storage"], "Worked on a rename")

    count_reads(session)
    reconnect(session)
    assert run(session, "return window.draftReads") == 0

    session
    |> assert_value("#review_body", "Worked on a rename")
    |> assert_value("#review_model_id", "")
    |> assert_value("#review_environment_id", "ide")

    assert hidden_record(session)["submission_key"] == before["submission_key"]
    assert run(session, "return window.draftReads") == 0

    fill_in(session, text_field("Review"), with: "Worked on a rename, twice")

    # Saved under the pair the hook kept: a stale pair would conflict instead.
    assert %{"draft" => pair, "intent" => %{"attrs" => attrs}} =
             saved(session, before["storage"], "Worked on a rename, twice")

    assert pair["draft_id"] == first_pair["draft_id"] and
             pair["revision"] > first_pair["revision"]

    assert %{"model_id" => "", "environment_id" => "ide"} = attrs
    refute_has(session, css(status, text: "paused"))
  end

  feature "without browser storage the author keeps composing and is told the draft isn't saved",
          %{session: session, status: status} do
    open_editor(session, "/editor/tips/new")
    run(session, "window.liveSocket.enableLatencySim(1000)")
    visit(session, "/editor/tips/new")

    run(session, """
    Object.defineProperty(window, "indexedDB", {value: undefined, configurable: true})
    window.liveSocket.disableLatencySim()
    """)

    session
    |> assert_has(css(".phx-connected"))
    |> fill_in(text_field("Title"), with: "Still typing")
    |> assert_has(css(status, text: "Draft couldn't be saved; keep this page open."))
    |> assert_value("#tip_title", "Still typing")
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

  # Creates the form's slot draft under a new submission key, with saved text.
  defp seed(session, title, body) do
    key = Ecto.UUID.generate()
    record = hidden_record(session)

    record =
      %{record | "draft" => %{"draft_id" => key, "revision" => 0}, "submission_key" => key}
      |> put_in(["intent", "attrs", "title"], title)
      |> put_in(["intent", "attrs", "body"], body)

    assert %{"status" => "ok", "record" => ^record} =
             run(session, "return (await importStore()).create(args[0])", [record])

    record
  end

  defp stored(session, storage) do
    %{"status" => "ok", "record" => record} =
      run(session, "return (await importStore()).load(args[0])", [storage])

    record
  end

  # The stored draft once autosave has written `body`. The status line alone
  # cannot tell one save from the next.
  defp saved(session, storage, body) do
    run(
      session,
      """
      const store = await importStore()
      const deadline = Date.now() + 3000
      for (;;) {
        const result = await store.load(args[0])
        if (result.record?.intent.attrs.body === args[1] || Date.now() > deadline) return result.record
        await new Promise((resolve) => setTimeout(resolve, 50))
      }
      """,
      [storage, body]
    )
  end

  # Waits for the editor's queued storage reads to settle: a readwrite
  # transaction starts only after them.
  defp settle_store(session) do
    run(session, """
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("tips-editor-drafts")
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
    const transaction = db.transaction("drafts", "readwrite")
    transaction.objectStore("drafts").get(0)
    await new Promise((resolve, reject) => {
      transaction.oncomplete = resolve
      transaction.onabort = () => reject(transaction.error)
    })
    db.close()
    """)
  end

  # Starts saving `body` over `record` in `tab`, queued behind the held store,
  # and returns once its transaction exists.
  defp queue_save(session, tab, record, body) do
    focus_window(session, tab)

    run(
      session,
      """
      const store = await importStore()
      const transaction = IDBDatabase.prototype.transaction
      const created = new Promise((resolve) => {
        IDBDatabase.prototype.transaction = function () {
          IDBDatabase.prototype.transaction = transaction
          resolve()
          return transaction.apply(this, arguments)
        }
      })
      store.save(args[0].storage, args[0].draft, args[1])
      await created
      """,
      [record, put_in(record, ["intent", "attrs", "body"], body)]
    )
  end

  # Counts the page's storage reads in `window.draftReads`.
  defp count_reads(session) do
    run(session, """
    window.draftReads = 0
    const transaction = IDBDatabase.prototype.transaction
    IDBDatabase.prototype.transaction = function (store, mode) {
      if (mode !== "readwrite") window.draftReads += 1
      return transaction.apply(this, arguments)
    }
    """)
  end

  defp await_reads(session, count) do
    run(
      session,
      """
      const deadline = Date.now() + 5000
      while (window.draftReads < args[0]) {
        if (Date.now() > deadline) throw new Error(`${window.draftReads} storage reads`)
        await new Promise((resolve) => setTimeout(resolve, 50))
      }
      """,
      [count]
    )
  end

  defp reconnect(session) do
    run(session, """
    const main = document.querySelector("[data-phx-main]")
    const until = async (test) => { while (!test()) await new Promise((r) => setTimeout(r, 50)) }
    window.liveSocket.disconnect()
    await until(() => !main.classList.contains("phx-connected"))
    window.liveSocket.connect()
    await until(() => main.classList.contains("phx-connected"))
    """)
  end

  defp hidden_record(session) do
    run(session, ~s|return JSON.parse(document.querySelector("[name='editor[record]']").value)|)
  end

  defp assert_value(session, selector, value) do
    assert run(session, "return document.querySelector(args[0]).value", [selector]) == value
    session
  end

  defp open_tab(session) do
    tabs = window_handles(session)
    execute_script(session, "window.open('about:blank', '_blank')")
    [tab] = window_handles(session) -- tabs
    tab
  end

  # Holds a readwrite transaction on the draft store in `tab`, so the editor's
  # read queues behind it, until `release_store/2` or 20 seconds.
  defp hold_store(session, tab) do
    session
    |> focus_window(tab)
    |> visit("/")

    run(session, """
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("tips-editor-drafts")
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
    const transaction = db.transaction("drafts", "readwrite")
    const store = transaction.objectStore("drafts")
    const deadline = Date.now() + 20000
    window.held = true
    const spin = () => {
      if (window.held && Date.now() < deadline) store.get(0).onsuccess = spin
    }
    spin()
    window.blocker = new Promise((resolve) => {
      transaction.oncomplete = transaction.onabort = () => {
        db.close()
        resolve(!window.held)
      }
    })
    """)
  end

  defp release_store(session, tab) do
    focus_window(session, tab)
    assert run(session, "window.held = false; return await window.blocker"), "the blocker expired"
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

    case WebdriverClient.execute_script_async(session, script, [File.read!(@store_source) | args]) do
      {:ok, %{"ok" => value}} -> value
      {:ok, %{"error" => error}} -> flunk("browser script failed:\n" <> error)
    end
  end
end
