defmodule TipsWeb.EditorDraftStoreTest do
  @moduledoc """
  Real-browser tests of the IndexedDB draft store, `assets/js/editor_draft_store.js`.

  Each page imports the production source through a Blob URL, so tests need no
  route, global or build entry. Races hold a real readwrite blocker transaction
  until both racers have queued theirs. Injected failures (no IndexedDB, a denied
  open, a quota-named error on a really aborted transaction) test how the store
  classifies errors, not real disk exhaustion.
  """
  use Tips.FeatureCase, async: true

  alias Wallaby.WebdriverClient

  @moduletag :browser

  @store_source Path.expand("../../../assets/js/editor_draft_store.js", __DIR__)
  @invalid %{"status" => "error", "reason" => "invalid"}

  # Installed in every test page. The database names must match the store's.
  @harness ~S"""
  const source = arguments[0]
  const DATABASE = "tips-editor-drafts"
  const VERSION = 1
  const STORE = "drafts"
  const RACE = "editor-draft-race"
  const BLOCK_LIMIT_MS = 10000

  const settle = (promise) =>
    promise.then((value) => value, (error) => ({thrown: String(error?.stack ?? error)}))

  async function importStore() {
    const url = URL.createObjectURL(new Blob([source], {type: "text/javascript"}))
    try {
      return await import(url)
    } finally {
      URL.revokeObjectURL(url)
    }
  }

  function openDatabase() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(DATABASE)
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }

  async function checkDatabase() {
    const db = await openDatabase()
    const {version} = db
    const found = db.objectStoreNames.contains(STORE)
    db.close()
    if (version !== VERSION || !found) {
      throw new Error(`harness database names do not match the store: version ${version}, store ${found}`)
    }
  }

  // Holds a readwrite transaction on the store until two racers have queued
  // their transactions, so neither racer's transaction can start before both
  // exist. Bounded: an expired blocker lets the racers run and is reported.
  async function block() {
    const db = await openDatabase()
    const channel = new BroadcastChannel(RACE)
    const transaction = db.transaction(STORE, "readwrite")
    const store = transaction.objectStore(STORE)
    const deadline = Date.now() + BLOCK_LIMIT_MS
    let queued = 0
    let released = null
    channel.onmessage = () => {
      queued += 1
      if (queued >= 2 && released === null) released = queued
    }
    const done = new Promise((resolve) => {
      transaction.oncomplete = transaction.onabort = () => {
        channel.close()
        db.close()
        resolve({released: released ?? queued, expired: released === null})
      }
    })
    const spin = () => {
      if (released === null && Date.now() < deadline) store.get(0).onsuccess = spin
    }
    spin()
    return {done}
  }

  // Reports each transaction this page creates to the blocker. Observes only.
  function observe() {
    const original = IDBDatabase.prototype.transaction
    const channel = new BroadcastChannel(RACE)
    IDBDatabase.prototype.transaction = function (...args) {
      const transaction = original.apply(this, args)
      channel.postMessage("queued")
      return transaction
    }
    return () => {
      IDBDatabase.prototype.transaction = original
      channel.close()
    }
  }

  async function race(start) {
    await checkDatabase()
    const blocker = await block()
    const stopObserving = observe()
    try {
      const pending = start().map(settle)
      const schedule = await blocker.done
      return {schedule, results: await Promise.all(pending)}
    } finally {
      stopObserving()
    }
  }

  function place(root, path, value) {
    const parent = path.slice(0, -1).reduce((node, key) => node[key], root)
    parent[path[path.length - 1]] = value
  }

  const binaries = {
    blob: () => new Blob(["image bytes"], {type: "image/png"}),
    file: () => new File(["image bytes"], "photo.png", {type: "image/png"}),
    array_buffer: () => new Uint8Array([137, 80, 78, 71]).buffer,
    map: () => new Map([["body", "text"]]),
  }

  function hideIndexedDB() {
    const own = Object.getOwnPropertyDescriptor(window, "indexedDB")
    Object.defineProperty(window, "indexedDB", {value: undefined, configurable: true, writable: true})
    return () => {
      if (own) Object.defineProperty(window, "indexedDB", own)
      else delete window.indexedDB
    }
  }

  function denyOpen() {
    const open = IDBFactory.prototype.open
    IDBFactory.prototype.open = function () {
      throw new DOMException("injected denial", "SecurityError")
    }
    return () => {
      IDBFactory.prototype.open = open
    }
  }

  // Aborts the real transaction after its put succeeds. With quota, that
  // transaction's error reads as a QuotaExceededError, as a full disk reports.
  function abortAfterPut(quota) {
    const put = IDBObjectStore.prototype.put
    const error = Object.getOwnPropertyDescriptor(IDBTransaction.prototype, "error")
    const quotaFailed = new WeakSet()
    IDBObjectStore.prototype.put = function (...args) {
      const request = put.apply(this, args)
      const {transaction} = this
      request.addEventListener("success", () => {
        if (quota) quotaFailed.add(transaction)
        transaction.abort()
      })
      return request
    }
    Object.defineProperty(IDBTransaction.prototype, "error", {
      ...error,
      get() {
        return quotaFailed.has(this)
          ? new DOMException("injected quota", "QuotaExceededError")
          : error.get.call(this)
      },
    })
    return () => {
      IDBObjectStore.prototype.put = put
      Object.defineProperty(IDBTransaction.prototype, "error", error)
    }
  }

  const injections = {
    unavailable: hideIndexedDB,
    denied: denyOpen,
    abort: () => abortAfterPut(false),
    quota: () => abortAfterPut(true),
  }

  // Temporary negative control (#75 c2, removed in c3): reads in one
  // transaction and blindly puts in another, reporting ok only after the put's
  // transaction completes. Its only defect is the split read/compare/write.
  function splitKey({account_id, slot}) {
    if (slot.tag === "new_tip") return [account_id, "new_tip"]
    if (slot.tag === "new_review") return [account_id, "new_review", slot.tip_id]
    return [account_id, "edit", slot.kind, slot.id]
  }

  function splitStep(db, mode, step) {
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(STORE, mode)
      let result
      step(transaction.objectStore(STORE)).onsuccess = (event) => {
        result = event.target.result
      }
      transaction.oncomplete = () => resolve(result)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  const split = {
    async create(record) {
      const db = await openDatabase()
      const key = splitKey(record.storage)
      if ((await splitStep(db, "readonly", (store) => store.get(key))) !== undefined) {
        return {status: "conflict"}
      }
      await splitStep(db, "readwrite", (store) => store.put(record, key))
      return {status: "ok", record}
    },

    async save(storage, expected, record) {
      const db = await openDatabase()
      const key = splitKey(storage)
      const stored = await splitStep(db, "readonly", (store) => store.get(key))
      const {draft_id, revision} = stored?.draft ?? {}
      if (draft_id !== expected.draft_id || revision !== expected.revision) return {status: "conflict"}
      const next = {...record, draft: {draft_id, revision: revision + 1}}
      await splitStep(db, "readwrite", (store) => store.put(next, key))
      return {status: "ok", record: next}
    },
  }

  const racer = () => (window.draftHarness.racerImpl === "split" ? split : importStore())

  const webStorage = () =>
    JSON.stringify([Object.entries(localStorage), Object.entries(sessionStorage)])

  window.draftHarness = {
    importStore,
    checkDatabase,
    settle,
    block,
    observe,

    // Starts a create without waiting for it; the result lands in pending.
    async startCreate(record) {
      const store = await racer()
      observe()
      this.pending = settle(store.create(record))
    },

    async saveRace(storage, expected, first, second) {
      const racers = [await racer(), await racer()]
      const outcome = await race(() => [
        racers[0].save(storage, expected, first),
        racers[1].save(storage, expected, second),
      ])
      return {...outcome, stored: await (await importStore()).load(storage)}
    },

    // Runs operations in order on one store instance and returns their
    // results, whether any input changed, and whether Web Storage changed.
    async perform(ops) {
      const before = webStorage()
      let store = await importStore()
      let inputsUnchanged = true
      const results = []
      for (const op of ops) {
        if (op.fresh) store = await importStore()
        if (op.poison) place(op.args, op.poison.path, binaries[op.poison.value]())
        const snapshot = JSON.stringify(op.args)
        const restore = op.inject ? injections[op.inject]() : () => {}
        try {
          const pending = store[op.call](...op.args)
          if (op.mutate) place(op.args, op.mutate.path, op.mutate.value)
          results.push(await pending)
        } finally {
          restore()
        }
        if (!op.mutate && JSON.stringify(op.args) !== snapshot) inputsUnchanged = false
      }
      return {results, inputs_unchanged: inputsUnchanged, web_storage_unchanged: webStorage() === before}
    },
  }
  """

  feature "concurrent first writers create only one account/form draft", %{session: session} do
    storage = storage(101, %{tag: "new_tip"})
    first = new_tip(storage, "draft-first", "Typed in the first tab")
    second = new_tip(storage, "draft-second", "Typed in the second tab")

    winner = race_first_creation(session, first, second)
    assert winner in [wire(first), wire(second)]

    assert run(session, "return (await h.importStore()).load(args[0])", [storage]) ==
             %{"status" => "ok", "record" => winner}
  end

  feature "stale writers preserve newer and replacement drafts", %{session: session} do
    storage = storage(101, %{tag: "new_tip"})
    seed = new_tip(storage, "draft-raced", "Seed")
    open_store_page(session)

    raced = save_race(session, seed, storage)
    assert raced["draft"] == %{"draft_id" => "draft-raced", "revision" => 1}

    stale = %{draft_id: "draft-raced", revision: 0}
    current = %{draft_id: "draft-raced", revision: 1}
    replacement = new_tip(storage, "draft-replacement", "Started after discard")
    replaced = %{draft_id: "draft-replacement", revision: 0}

    replacement_saved =
      put_in(replacement.intent.attrs.body, "Replacement saved once")
      |> Map.put(:draft, %{replaced | revision: 1})

    assert %{
             results: [
               stale_save,
               stale_discard,
               stale_clear,
               after_stale,
               aborted,
               after_abort,
               discarded,
               missing_save,
               missing_discard,
               missing_clear,
               recreated,
               replacement_save,
               old_save,
               old_discard,
               old_clear,
               after_old,
               cleared,
               after_clear
             ],
             inputs_unchanged: true,
             web_storage_unchanged: true
           } =
             perform(session, [
               op(:save, [storage, stale, edited(seed, stale, "Stale tab")]),
               op(:discard, [storage, stale]),
               op(:clear, [storage, stale]),
               op(:load, [storage]),
               op(:save, [storage, current, edited(seed, current, "Lost to abort")],
                 inject: :abort
               ),
               op(:load, [storage]),
               op(:discard, [storage, current]),
               op(:save, [storage, current, edited(seed, current, "After discard")]),
               op(:discard, [storage, current]),
               op(:clear, [storage, current]),
               op(:create, [replacement]),
               op(:save, [storage, replaced, %{replacement_saved | draft: replaced}]),
               op(:save, [storage, current, edited(seed, current, "Old editor")]),
               op(:discard, [storage, current]),
               op(:clear, [storage, current]),
               op(:load, [storage]),
               op(:clear, [storage, %{replaced | revision: 1}]),
               op(:load, [storage])
             ])

    for {label, result} <- [
          stale_save: stale_save,
          stale_discard: stale_discard,
          stale_clear: stale_clear
        ] do
      assert result == %{"status" => "conflict"}, "#{label} must not touch the newer draft"
    end

    assert after_stale == %{"status" => "ok", "record" => raced}

    assert aborted == %{"status" => "error", "reason" => "failed"},
           "a put that succeeded before its transaction aborted is not saved"

    assert after_abort == %{"status" => "ok", "record" => raced}, "the abort rolled back"
    assert discarded == %{"status" => "ok"}

    for {label, result} <- [
          missing_save: missing_save,
          missing_discard: missing_discard,
          missing_clear: missing_clear,
          old_save: old_save,
          old_discard: old_discard,
          old_clear: old_clear
        ] do
      assert result == %{"status" => "conflict"},
             "#{label}: a missing or replaced draft conflicts at the same revision"
    end

    assert recreated == %{"status" => "ok", "record" => wire(replacement)}
    assert replacement_save == %{"status" => "ok", "record" => wire(replacement_saved)}
    assert after_old == %{"status" => "ok", "record" => wire(replacement_saved)}
    assert cleared == %{"status" => "ok"}
    assert after_clear == %{"status" => "ok", "record" => nil}
  end

  feature "records keep their slot and exact content", %{session: session} do
    tip = storage(101, %{tag: "new_tip"})
    other_account = storage(202, %{tag: "new_tip"})
    review_7 = storage(101, %{tag: "new_review", tip_id: 7})
    review_8 = storage(101, %{tag: "new_review", tip_id: 8})
    edit_tip_9 = storage(101, %{tag: "edit", kind: "tip", id: 9})
    edit_review_9 = storage(101, %{tag: "edit", kind: "review", id: 9})
    empty = storage(303, %{tag: "new_tip"})
    open_store_page(session)

    k = %{new_tip(tip, "draft-k", "  Body kept verbatim \n\r\n\t ") | intent: rich_intent()}
    k_pair = k.draft

    handoff = %{
      k
      | mode: "edit",
        target: edit_tip_9.slot,
        base: base_intent(),
        expected_version: 3
    }

    e = %{
      storage: edit_tip_9,
      draft: %{draft_id: "draft-e", revision: 0},
      mode: "edit",
      target: edit_tip_9.slot,
      submission_key: nil,
      intent: %{attrs: %{body: "Separate edit draft"}, uploads: nil},
      base: base_intent(),
      expected_version: 3
    }

    review = %{
      storage: review_7,
      draft: %{draft_id: "draft-review-7", revision: 0},
      mode: "new",
      target: review_7.slot,
      submission_key: "draft-review-7",
      intent: %{attrs: %{body: "", prompt: nil}, uploads: []},
      base: nil,
      expected_version: nil
    }

    snapshotted = %{review | storage: review_8, target: review_8.slot}

    assert %{
             results: [
               k_created,
               e_created,
               review_created,
               other_load,
               other_save,
               other_discard,
               review_8_load,
               edit_review_load,
               handed_off,
               k_load,
               e_load,
               review_load,
               snapshot_created,
               snapshot_load
             ],
             inputs_unchanged: true,
             web_storage_unchanged: true
           } =
             perform(session, [
               op(:create, [k]),
               op(:create, [e]),
               op(:create, [review]),
               op(:load, [other_account]),
               op(:save, [other_account, k_pair, %{k | storage: other_account}]),
               op(:discard, [other_account, k_pair]),
               op(:load, [review_8]),
               op(:load, [edit_review_9]),
               op(:save, [tip, k_pair, handoff]),
               op(:load, [tip]),
               op(:load, [edit_tip_9]),
               op(:load, [review_7]),
               op(:create, [snapshotted],
                 mutate: %{path: [0, "intent", "attrs", "body"], value: "Changed after the call"}
               ),
               op(:load, [review_8])
             ])

    assert k_created == %{"status" => "ok", "record" => wire(k)}
    assert e_created == %{"status" => "ok", "record" => wire(e)}
    assert review_created == %{"status" => "ok", "record" => wire(review)}
    assert other_load == %{"status" => "ok", "record" => nil}
    assert other_save == %{"status" => "conflict"}, "another account cannot overwrite"
    assert other_discard == %{"status" => "conflict"}, "another account cannot discard"
    assert review_8_load == %{"status" => "ok", "record" => nil}
    assert edit_review_load == %{"status" => "ok", "record" => nil}

    handed_off_record = wire(%{handoff | draft: %{k_pair | revision: 1}})
    assert handed_off == %{"status" => "ok", "record" => handed_off_record}
    assert k_load == %{"status" => "ok", "record" => handed_off_record}, "the handoff stays in K"
    assert e_load == %{"status" => "ok", "record" => wire(e)}, "the handoff leaves E unchanged"
    assert review_load == %{"status" => "ok", "record" => wire(review)}

    assert snapshot_created == %{"status" => "ok", "record" => wire(snapshotted)},
           "the store keeps the record as it was when called, and does not alias it"

    assert snapshot_load == %{"status" => "ok", "record" => wire(snapshotted)}

    fresh = new_tip(empty, "draft-invalid", "Never stored")
    review_slot_tip_attrs = put_in(review.intent.attrs[:title], "Reviews have no title")
    max_pair = %{draft_id: "draft-k", revision: 9_007_199_254_740_991}

    invalid_ops = [
      blob_text: op(:create, [fresh], poison: [0, "intent", "attrs", "body"], value: :blob),
      file_upload: op(:create, [fresh], poison: [0, "intent", "uploads", 0], value: :file),
      array_buffer:
        op(:create, [fresh], poison: [0, "intent", "attrs", "prompt"], value: :array_buffer),
      map_attrs: op(:create, [fresh], poison: [0, "intent", "attrs"], value: :map),
      extra_record_key: op(:create, [Map.put(fresh, :bytes, "aGVsbG8=")]),
      extra_media_key:
        op(:create, [
          put_in(fresh.intent.uploads, [%{tag: "staged_video", media_id: 4, url: "https://x"}])
        ]),
      tip_attr_on_review:
        op(:create, [
          %{review_slot_tip_attrs | storage: storage(303, review_7.slot), target: review_7.slot}
        ]),
      string_account: op(:create, [%{fresh | storage: %{empty | account_id: "303"}}]),
      created_at_revision_1: op(:create, [%{fresh | draft: %{fresh.draft | revision: 1}}]),
      empty_submission_key: op(:create, [%{fresh | submission_key: ""}]),
      new_mode_edit_target: op(:create, [%{fresh | target: edit_tip_9.slot}]),
      cross_kind_handoff: op(:create, [%{fresh | mode: "edit", target: edit_review_9.slot}]),
      save_other_storage:
        op(:save, [
          tip,
          %{k_pair | revision: 1},
          %{handoff | draft: %{k_pair | revision: 1}, storage: other_account}
        ]),
      save_other_pair: op(:save, [tip, %{k_pair | revision: 1}, handoff]),
      unsafe_revision: op(:save, [tip, max_pair, %{handoff | draft: max_pair}])
    ]

    assert %{results: results, inputs_unchanged: true, web_storage_unchanged: true} =
             perform(
               session,
               Keyword.values(invalid_ops) ++ [op(:load, [empty]), op(:load, [tip])]
             )

    {invalid_results, [empty_load, tip_load]} = Enum.split(results, length(invalid_ops))

    assert Enum.reject(
             Enum.zip(Keyword.keys(invalid_ops), invalid_results),
             &(elem(&1, 1) == @invalid)
           ) ==
             [],
           "each listed input must be rejected as invalid"

    assert empty_load == %{"status" => "ok", "record" => nil}, "nothing invalid was stored"
    assert tip_load == %{"status" => "ok", "record" => handed_off_record}
  end

  feature "storage failures return unsaved risk", %{session: session} do
    storage = storage(101, %{tag: "new_tip"})
    draft = new_tip(storage, "draft-risk", "Keep this on screen")
    pair = draft.draft
    next = edited(draft, pair, "Not saved: quota")
    open_store_page(session)

    assert %{
             results: [unavailable, recovered, denied, after_denied, quota, after_quota],
             inputs_unchanged: true,
             web_storage_unchanged: true
           } =
             perform(session, [
               op(:create, [draft], inject: :unavailable, fresh: true),
               op(:create, [draft]),
               op(:load, [storage], inject: :denied, fresh: true),
               op(:load, [storage]),
               op(:save, [storage, pair, next], inject: :quota),
               op(:load, [storage])
             ])

    assert unavailable == %{"status" => "error", "reason" => "unavailable"}
    assert recovered == %{"status" => "ok", "record" => wire(draft)}, "a failed open is retried"
    assert denied == %{"status" => "error", "reason" => "unavailable"}
    assert after_denied == %{"status" => "ok", "record" => wire(draft)}
    assert quota == %{"status" => "error", "reason" => "quota"}
    assert after_quota == %{"status" => "ok", "record" => wire(draft)}
  end

  # Temporary negative controls (c2 only): the same race helpers and CAS
  # assertions must reject a split read-then-write store.
  feature "negative control: split creation fails the first-writer assertion", %{
    session: session
  } do
    storage = storage(101, %{tag: "new_tip"})
    first = new_tip(storage, "draft-first", "Typed in the first tab")
    second = new_tip(storage, "draft-second", "Typed in the second tab")

    error =
      assert_raise ExUnit.AssertionError, fn ->
        race_first_creation(session, first, second, "split")
      end

    IO.puts("negative control (two-tab create): " <> error.message)
    assert error.message == "expected exactly one ok and one conflict, got two ok"
  end

  feature "negative control: split saving fails the stale-writer assertion", %{session: session} do
    storage = storage(101, %{tag: "new_tip"})
    open_store_page(session)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        save_race(session, new_tip(storage, "draft-raced", "Seed"), storage, "split")
      end

    IO.puts("negative control (same-page save): " <> error.message)
    assert error.message == "expected exactly one ok and one conflict, got two ok"
  end

  defp open_store_page(session) do
    session
    |> visit("/")
    |> execute_script(@harness, [File.read!(@store_source)])
  end

  # Runs an async script body with `h` (the harness) and `args`. JS errors fail
  # the test; the WebDriver script timeout bounds it.
  defp run(session, body, args \\ []) do
    script = """
    const done = arguments[arguments.length - 1]
    const args = Array.from(arguments).slice(0, -1)
    const h = window.draftHarness
    ;(async () => {
    #{body}
    })().then(
      (value) => done({ok: value ?? null}),
      (error) => done({error: String(error?.stack ?? error)}),
    )
    """

    case WebdriverClient.execute_script_async(session, script, args) do
      {:ok, %{"ok" => value}} -> value
      {:ok, %{"error" => error}} -> flunk("browser script failed:\n" <> error)
    end
  end

  defp perform(session, ops) do
    %{"results" => results, "inputs_unchanged" => inputs, "web_storage_unchanged" => web_storage} =
      run(session, "return h.perform(args[0])", [ops])

    %{results: results, inputs_unchanged: inputs, web_storage_unchanged: web_storage}
  end

  # Two tabs of one profile each create the same slot behind the blocker.
  defp race_first_creation(session, first, second, impl \\ "store") do
    first_tab = session |> open_store_page() |> window_handle()

    assert run(session, "return (await h.importStore()).load(args[0])", [first.storage]) ==
             %{"status" => "ok", "record" => nil}

    run(
      session,
      "h.racerImpl = args[1]; await h.checkDatabase(); h.blocker = await h.block(); await h.startCreate(args[0])",
      [first, impl]
    )

    execute_script(session, "window.open('about:blank', '_blank')")
    [second_tab] = window_handles(session) -- [first_tab]
    session |> focus_window(second_tab) |> open_store_page()
    run(session, "h.racerImpl = args[1]; await h.startCreate(args[0])", [second, impl])
    second_result = run(session, "return h.pending")

    focus_window(session, first_tab)

    %{"schedule" => schedule, "result" => first_result} =
      run(session, "return {schedule: await h.blocker.done, result: await h.pending}")

    assert_schedule(schedule)
    assert_one_winner([first_result, second_result])
  end

  defp save_race(session, seed, storage, impl \\ "store") do
    expected = seed.draft
    first = edited(seed, expected, "First racer")
    second = edited(seed, expected, "Second racer")

    assert run(session, "return (await h.importStore()).create(args[0])", [seed]) ==
             %{"status" => "ok", "record" => wire(seed)}

    %{"schedule" => schedule, "results" => results, "stored" => stored} =
      run(session, "h.racerImpl = args[4]; return h.saveRace(...args)", [
        storage,
        expected,
        first,
        second,
        impl
      ])

    assert_schedule(schedule)
    winner = assert_one_winner(results)

    assert winner in [
             wire(%{first | draft: %{expected | revision: 1}}),
             wire(%{second | draft: %{expected | revision: 1}})
           ]

    assert stored == %{"status" => "ok", "record" => winner}
    winner
  end

  defp assert_schedule(schedule) do
    assert schedule == %{"released" => 2, "expired" => false},
           "both racers must queue behind the blocker: #{inspect(schedule)}"
  end

  defp assert_one_winner(results) do
    statuses = Enum.map(results, & &1["status"])
    got = if statuses == ["ok", "ok"], do: "two ok", else: inspect(results)

    assert Enum.sort(statuses) == ["conflict", "ok"],
           "expected exactly one ok and one conflict, got #{got}"

    assert %{"status" => "conflict"} in results
    [%{"record" => winner}] = Enum.filter(results, &(&1["status"] == "ok"))
    winner
  end

  defp op(call, args, opts \\ []) do
    %{call: call, args: args}
    |> put_opt(:inject, opts[:inject])
    |> put_opt(:fresh, opts[:fresh])
    |> put_opt(:mutate, opts[:mutate])
    |> put_opt(:poison, opts[:poison] && %{path: opts[:poison], value: opts[:value]})
  end

  defp put_opt(op, _key, nil), do: op
  defp put_opt(op, key, value), do: Map.put(op, key, value)

  defp storage(account_id, slot), do: %{account_id: account_id, slot: slot}

  defp new_tip(storage, draft_id, body) do
    %{
      storage: storage,
      draft: %{draft_id: draft_id, revision: 0},
      mode: "new",
      target: storage.slot,
      submission_key: draft_id,
      intent: %{attrs: %{title: "Draft title", body: body}, uploads: []},
      base: nil,
      expected_version: nil
    }
  end

  defp edited(record, pair, body), do: %{put_in(record.intent.attrs.body, body) | draft: pair}

  defp rich_intent do
    %{
      attrs: %{
        title: "",
        body: "  Body kept verbatim \n\r\n\t ",
        tag_id: nil,
        model_id: "12",
        model_other: "   ",
        environment_id: nil,
        prompt: "Prompt with émoji 🧪 and \"quotes\"",
        output: "Output\n\nwith blank lines"
      },
      uploads: [
        %{
          tag: "missing_image",
          slot: "img-2",
          filename: "diagram.png",
          type: "image/png",
          size: 52_100,
          description: "Second"
        },
        %{tag: "staged_video", media_id: 41},
        %{tag: "retained", media_id: 40, description: nil},
        %{tag: "missing_image", slot: "img-1", filename: "", type: "", size: 0, description: ""}
      ]
    }
  end

  defp base_intent do
    %{
      attrs: %{title: "Published", body: "Published body", model_id: nil},
      uploads: [%{tag: "retained", media_id: 40, description: "Kept"}]
    }
  end

  defp wire(value), do: value |> JSON.encode!() |> JSON.decode!()
end
