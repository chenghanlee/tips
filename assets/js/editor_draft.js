// EditorDraft: the draft hook of the tip and review editors. It restores a
// browser draft on a fresh mount and autosaves typing to the account/form
// slot. The page side is TipsWeb.Editor; the rules are "Saving and recovery"
// in docs/design/frontend-design.md.
//
// A fresh mount reads the slot once. It applies the saved draft only while
// the form still shows what the page rendered and nothing was typed, so
// typing before the hook started or during a slow read stays. Otherwise, and
// when the page rejects the draft, autosave pauses so it cannot overwrite the
// saved draft. A paused editor offers "Reload saved draft", which replaces
// the input with the saved draft and resumes autosave; typing during that
// read stays and keeps autosave paused. The hook sends
// editor:restore only to apply a draft; the page replies "restored",
// "published" or "rejected".
//
// A reconnect reads no storage: LiveView recovers the form through
// editor:recover, and this hook keeps its draft pair. A read still pending at
// a disconnect never restores. Results that arrive after the hook is
// destroyed, or after a reload or restore fell back on disconnect, are
// ignored.
// Autosave starts once recovery settles.
//
// The page renders the current attachment selection in data-editor-record on
// every change. A save writes the selection rendered at that moment, and a
// rendered selection that differs from the last one schedules a save like
// typing does. One that arrives while a submit awaits the page's answer waits
// for it, so it cannot replace the revision a confirmed receipt clears; it is
// saved if the draft stays.
//
// After a submit fails validation (editor:refused), the hook opens the
// evidence disclosure when it holds an invalid field and focuses the error
// summary. A summary link focuses its field.
//
// A submit saves exactly the submitted values first. When the page confirms
// them (editor:clear), the hook clears the revision that holds them, only
// while the slot still holds it, and reports the result (editor:cleared);
// the page then leaves, or stays when other work kept the draft. If that
// report is lost, or the page reconnects after the clear, the hook leaves for
// the confirmed item itself. A restore the page answers "published" clears
// the restored revision the same way. editor:settled says whether the
// submission is still unresolved; after a reconnect, an unsettled submission
// is looked up again (editor:reconcile), as its reply may have been lost.

import {EDITOR_EVENTS} from "./editor_contract.js"
import {clear, create, load, save} from "./editor_draft_store.js"

const SAVE_DELAY_MS = 500

const FIELDS = {
  tip: ["title", "body", "tag_id", "model_id", "model_other", "environment_id", "prompt", "output"],
  review: ["body", "model_id", "model_other", "environment_id", "prompt", "output"],
}

const STATUS = {
  restored: "Recovered your draft from this browser.",
  unsaved: "Draft couldn't be saved; keep this page open.",
  paused:
    "Autosave is paused so it doesn't replace a draft saved earlier in this browser. Reloading the saved draft replaces what is on this page.",
  conflict:
    "This draft was changed in another tab. Autosave is paused. Reloading the saved draft replaces what is on this page.",
  rejected: "Autosave is paused so it doesn't replace a draft saved earlier in this browser. Keep this page open.",
  unread: "The saved draft couldn't be read. Autosave is paused; keep this page open.",
}

export const EditorDraft = {
  mounted() {
    this.identity = JSON.parse(this.el.dataset.editorIdentity)
    this.record = JSON.parse(this.el.dataset.editorRecord)
    this.kind = kindOf(this.identity.target)
    // The pair of the stored draft this page may replace; null until it holds one.
    this.expected = null
    // reading -> restoring -> composing or paused; paused -> reloading ->
    // restoring; composing or restoring -> clearing -> cleared or paused;
    // destroyed at the end.
    this.phase = "reading"
    this.connected = true
    // The page disconnected during the first read, so it recovered the form
    // from the DOM: that read never restores.
    this.interrupted = false
    // Tokens of the current reload read and restore; results for others are stale.
    this.reading = null
    this.pending = null
    this.timer = null
    // Draft writes run one at a time, in order.
    this.queue = Promise.resolve(null)
    // Resolves to {status, pair}: whether the last submitted values were saved,
    // and the pair that holds them.
    this.submission = null
    // Autosave paused because the slot holds other work.
    this.kept = false
    // Where a confirmed item is; the hook leaves for it after its clear.
    this.destination = null
    // A submission whose outcome the page has not settled.
    this.unsettled = false
    // A submit awaits the page's answer; a selection change meanwhile waits for it.
    this.submitting = false
    this.deferred = false
    this.typed = !sameAttrs(readAttrs(this.el, this.kind), this.record.intent.attrs, this.kind)
    // The selection last rendered by the page, as JSON.
    this.uploads = renderedUploads(this.el)
    this.onInput = () => {
      this.typed = true
      this.schedule()
    }
    this.el.addEventListener("input", this.onInput)
    this.onReload = () => this.reload()
    this.reloadButton().addEventListener("click", this.onReload)
    this.onClick = (event) => this.followError(event)
    this.el.addEventListener("click", this.onClick)
    this.onSubmit = () => this.submitted()
    this.el.addEventListener("submit", this.onSubmit)
    this.handleEvent(EDITOR_EVENTS.refused, () => this.showErrors())
    this.handleEvent(EDITOR_EVENTS.clear, (request) => this.clearSubmitted(request))
    this.handleEvent(EDITOR_EVENTS.settled, ({unresolved}) => {
      this.unsettled = unresolved
      this.submitting = false
      if (this.deferred) {
        this.deferred = false
        this.schedule()
      }
    })
    load(this.record.storage).then((result) => this.settleRead(result))
  },

  // A new selection is input. The record a restore renders is not.
  updated() {
    const uploads = renderedUploads(this.el)
    if (uploads === this.uploads) return
    this.uploads = uploads
    if (this.phase === "restoring") return
    this.typed = true
    if (this.submitting) this.deferred = true
    else this.schedule()
  },

  disconnected() {
    this.connected = false
    if (this.phase === "reading") this.interrupted = true
    // Its result is ignored; the author can reload again once connected.
    if (this.phase === "reloading") {
      this.reading = null
      this.pause(STATUS.paused, true)
    }
    // The reply cannot arrive now. Fall back to the unrestored form.
    if (this.phase === "restoring") {
      this.pending = null
      this.js().removeAttribute(this.fields(), "disabled")
      this.pause(STATUS.paused, true)
    }
  },

  reconnected() {
    this.connected = true
    // The remounted page no longer holds the confirmed receipt.
    if (this.phase === "cleared") this.leave()
    else if (this.unsettled) this.pushEvent(EDITOR_EVENTS.reconcile, {}, () => {})
  },

  destroyed() {
    const unsaved = this.phase === "composing" && this.timer !== null
    const attrs = readAttrs(this.el, this.kind)
    clearTimeout(this.timer)
    this.timer = null
    this.phase = "destroyed"
    this.reading = null
    this.pending = null
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("submit", this.onSubmit)
    this.reloadButton().removeEventListener("click", this.onReload)
    // Best effort: the write may still finish after the page is gone.
    if (unsaved) this.enqueue(() => attrs)
  },

  settleRead(result) {
    if (this.phase !== "reading") return
    if (result.status !== "ok" || result.record === null) {
      // No draft, or storage failed: compose. A failed store reports itself on save.
      this.compose()
    } else if (this.typed || this.interrupted) {
      this.pause(STATUS.paused, true)
    } else {
      this.restore(result.record)
    }
  },

  // The author chose the saved draft over the input on the page at the click.
  async reload() {
    if (this.phase !== "paused" || !this.connected) return
    this.phase = "reloading"
    this.typed = false
    const token = {}
    this.reading = token
    const result = await load(this.record.storage)
    if (this.reading !== token) return
    this.reading = null
    if (result.status !== "ok") {
      this.pause(STATUS.unread, true, false)
    } else if (result.record === null) {
      // Nothing saved any more: keep the input and save it as a new draft.
      this.expected = null
      this.typed = true
      this.showReload(false)
      this.status("")
      this.compose()
    } else if (this.typed) {
      this.pause(STATUS.paused, true)
    } else {
      this.restore(result.record)
    }
  },

  restore(record) {
    this.phase = "restoring"
    const fields = this.fields()
    const focused = document.activeElement
    // Typing cannot race the restore while the fields are disabled.
    this.js().setAttribute(fields, "disabled", "")
    const token = {}
    this.pending = token
    this.pushEvent(EDITOR_EVENTS.restore, {identity: this.identity, record}, (reply) => {
      if (this.pending !== token) return
      this.pending = null
      if (reply.status === "published") {
        // The draft's publication is confirmed: the page restored it; clear it.
        this.record = record
        this.expected = record.draft
        this.destination = reply.to
        this.phase = "clearing"
        clear(record.storage, record.draft).then(({status}) => this.settleClear(status))
        return
      }
      this.js().removeAttribute(fields, "disabled")
      if (reply.status !== "restored") {
        this.pause(STATUS.rejected)
        return
      }
      this.record = record
      this.expected = record.draft
      const {prompt, output} = record.intent.attrs
      if (prompt || output) this.el.querySelector("details").open = true
      if (focused instanceof HTMLElement && this.el.contains(focused)) focused.focus()
      this.phase = "composing"
      this.showReload(false)
      this.status(STATUS.restored)
    })
  },

  compose() {
    this.phase = "composing"
    if (this.typed) this.schedule()
  },

  // `kept`: the slot holds other work than this page's input.
  pause(message, reloadable = false, kept = true) {
    clearTimeout(this.timer)
    this.timer = null
    this.phase = "paused"
    this.kept = kept
    this.showReload(reloadable)
    this.status(message)
  },

  showReload(shown) {
    if (shown) this.js().removeAttribute(this.reloadButton(), "hidden")
    else this.js().setAttribute(this.reloadButton(), "hidden", "")
  },

  schedule() {
    if (this.phase !== "composing") return
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.flush(), SAVE_DELAY_MS)
  },

  flush() {
    this.timer = null
    this.enqueue(() => (this.phase === "composing" ? readAttrs(this.el, this.kind) : null))
  },

  // Queues a write of the values `attrs` returns when the write starts; null
  // skips it. Resolves to the store's result, or null.
  enqueue(attrs) {
    const run = this.queue.then(() => {
      const values = attrs()
      return values === null ? null : this.write(values)
    })
    this.queue = run
    return run
  },

  // Creates the slot's draft at revision 0, then saves under the pair it holds.
  async write(attrs) {
    const draft = this.expected ?? {draft_id: this.record.draft.draft_id, revision: 0}
    const uploads = JSON.parse(renderedUploads(this.el))
    const record = {...this.record, draft, intent: {attrs, uploads}}
    const result =
      this.expected === null ? await create(record) : await save(record.storage, this.expected, record)
    if (this.phase === "destroyed") return result
    if (result.status === "ok") {
      this.record = result.record
      this.expected = result.record.draft
      if (this.phase === "composing") this.status(`Draft saved in this browser at ${clock()}`)
    } else if (this.phase !== "composing") {
      // A submission's write: the page decides what follows.
    } else if (result.status === "conflict") {
      this.pause(STATUS.conflict, true)
    } else {
      this.status(STATUS.unsaved)
    }
    return result
  },

  // The form is submitting the values on screen; LiveView keeps the inputs
  // read-only until the reply. Saves exactly these values, so that a
  // confirmed receipt clears the revision that holds them. A save conflict,
  // or autosave paused over other work, means the slot keeps other work.
  // An unrestored or unreadable editor holds no revision.
  submitted() {
    this.unsettled = true
    this.submitting = true
    if (this.phase !== "composing") {
      const status = this.phase === "paused" && this.kept ? "conflict" : "none"
      this.submission = Promise.resolve({status, pair: null})
      return
    }
    clearTimeout(this.timer)
    this.timer = null
    const attrs = readAttrs(this.el, this.kind)
    this.submission = this.enqueue(() => attrs).then((result) => ({
      status: result?.status ?? "none",
      pair: result?.status === "ok" ? result.record.draft : null,
    }))
  },

  // editor:clear: the page confirmed the submitted content. Clears the
  // revision that holds it, only if the slot still holds that revision.
  async clearSubmitted({storage, draft_id, to}) {
    this.destination = to
    if (this.phase === "cleared") return this.settleClear("ok")
    this.phase = "clearing"
    clearTimeout(this.timer)
    this.timer = null
    this.js().setAttribute(this.fields(), "disabled", "")
    const submitted = await (this.submission ?? {status: "none", pair: null})
    const ours =
      submitted.pair !== null && submitted.pair.draft_id === draft_id && sameStorage(storage, this.record.storage)
    const {status} = ours ? await clear(this.record.storage, submitted.pair) : submitted
    this.settleClear(ours || status === "conflict" ? status : "none")
  },

  // Reports the clear: "ok", "none" (no revision of ours held the values) or
  // "error" let the page leave; "conflict" keeps the other work and the
  // editor. If the page does not leave, as when the report is lost, the hook
  // leaves by itself.
  settleClear(status) {
    if (this.phase === "destroyed") return
    if (status === "conflict") {
      this.js().removeAttribute(this.fields(), "disabled")
      this.pause(STATUS.conflict, true)
      this.pushEvent(EDITOR_EVENTS.cleared, {status}, () => {})
      return
    }
    this.phase = "cleared"
    // A navigation across live sessions reloads the page and answers null.
    this.pushEvent(EDITOR_EVENTS.cleared, {status}).then(
      (reply) => reply?.left || this.leave(),
      () => this.leave(),
    )
  },

  leave() {
    if (this.phase === "cleared" && this.destination) window.location.assign(this.destination)
  },

  // The page has patched in the errors before this runs. LiveView then
  // refocuses the submit button when the submit settles, so focus after it.
  showErrors() {
    const details = this.el.querySelector("details")
    if (details?.querySelector('[aria-invalid="true"]')) details.open = true
    setTimeout(() => {
      if (this.phase !== "destroyed") this.errorSummary()?.focus()
    })
  },

  followError(event) {
    const link = event.target.closest("a[href^='#']")
    if (!link || !this.errorSummary()?.contains(link)) return
    const field = document.getElementById(link.getAttribute("href").slice(1))
    // Other targets keep the ordinary jump.
    if (!field?.matches("input, select, textarea")) return
    event.preventDefault()
    const details = field.closest("details")
    if (details) details.open = true
    field.focus()
  },

  errorSummary() {
    return this.el.querySelector(`#${CSS.escape(this.el.id)}-errors`)
  },

  fields() {
    return this.el.querySelector(`#${CSS.escape(this.el.id)}-fields`)
  },

  reloadButton() {
    return this.el.querySelector(`#${CSS.escape(this.el.id)}-reload`)
  },

  status(message) {
    this.el.querySelector(`#${CSS.escape(this.el.id)}-status`).textContent = message
  },
}

const NEW_KINDS = {new_tip: "tip", new_review: "review"}

const kindOf = (target) => (target.tag === "edit" ? target.kind : NEW_KINDS[target.tag])

// Every field of the kind as typed. The model select holds a curated id, ""
// or "other"; "other" means the typed model name.
function readAttrs(form, kind) {
  const value = (field) => form.elements.namedItem(`${kind}[${field}]`)?.value ?? null
  const attrs = Object.fromEntries(FIELDS[kind].map((field) => [field, value(field)]))
  return attrs.model_id === "other"
    ? {...attrs, model_id: null, model_other: attrs.model_other ?? ""}
    : {...attrs, model_other: null}
}

const renderedUploads = (form) => JSON.stringify(JSON.parse(form.dataset.editorRecord).intent.uploads)

// The form renders null as an empty field.
const sameAttrs = (a, b, kind) => FIELDS[kind].every((field) => (a[field] ?? "") === (b[field] ?? ""))

// Key order differs between the page's JSON and the store's copies.
const sameStorage = (a, b) =>
  a.account_id === b.account_id && ["tag", "tip_id", "kind", "id"].every((key) => a.slot[key] === b.slot[key])

const clock = () => new Date().toLocaleTimeString([], {hour: "numeric", minute: "2-digit"})
