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
// editor:restore only to apply a draft; the page replies "restored" or
// "rejected" ("preserved" keeps input like "rejected").
//
// A reconnect reads no storage: LiveView recovers the form through
// editor:recover, and this hook keeps its draft pair. A read still pending at
// a disconnect never restores. Results that arrive after the hook is
// destroyed, or after a reload or restore fell back on disconnect, are
// ignored.
// Autosave starts once recovery settles.
//
// After a submit fails validation (editor:refused), the hook opens the
// evidence disclosure when it holds an invalid field and focuses the error
// summary. A summary link focuses its field.

import {EDITOR_EVENTS} from "./editor_contract.js"
import {create, load, save} from "./editor_draft_store.js"

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
    // restoring; destroyed at the end.
    this.phase = "reading"
    this.connected = true
    // The page disconnected during the first read, so it recovered the form
    // from the DOM: that read never restores.
    this.interrupted = false
    // Tokens of the current reload read and restore; results for others are stale.
    this.reading = null
    this.pending = null
    this.timer = null
    this.writing = false
    this.again = false
    this.typed = !sameAttrs(readAttrs(this.el, this.kind), this.record.intent.attrs, this.kind)
    this.onInput = () => {
      this.typed = true
      this.schedule()
    }
    this.el.addEventListener("input", this.onInput)
    this.onReload = () => this.reload()
    this.reloadButton().addEventListener("click", this.onReload)
    this.onClick = (event) => this.followError(event)
    this.el.addEventListener("click", this.onClick)
    this.handleEvent(EDITOR_EVENTS.refused, () => this.showErrors())
    load(this.record.storage).then((result) => this.settleRead(result))
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
  },

  destroyed() {
    const unsaved = this.phase === "composing" && this.timer !== null
    clearTimeout(this.timer)
    this.timer = null
    this.phase = "destroyed"
    this.reading = null
    this.pending = null
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("click", this.onClick)
    this.reloadButton().removeEventListener("click", this.onReload)
    // Best effort: the write may still finish after the page is gone.
    if (unsaved) this.write()
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
      this.pause(STATUS.unread, true)
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

  pause(message, reloadable = false) {
    clearTimeout(this.timer)
    this.timer = null
    this.phase = "paused"
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

  // One write at a time; typing during a write saves again afterwards.
  async flush() {
    this.timer = null
    if (this.writing) {
      this.again = true
      return
    }
    this.writing = true
    do {
      this.again = false
      await this.write()
    } while (this.again && this.phase === "composing")
    this.writing = false
  },

  // Creates the slot's draft at revision 0, then saves under the pair it holds.
  async write() {
    const draft = this.expected ?? {draft_id: this.record.draft.draft_id, revision: 0}
    const intent = {attrs: readAttrs(this.el, this.kind), uploads: this.record.intent.uploads}
    const record = {...this.record, draft, intent}
    const result =
      this.expected === null ? await create(record) : await save(record.storage, this.expected, record)
    if (this.phase === "destroyed") return
    if (result.status === "ok") {
      this.record = result.record
      this.expected = result.record.draft
      if (this.phase === "composing") this.status(`Draft saved in this browser at ${clock()}`)
    } else if (result.status === "conflict") {
      this.pause(STATUS.conflict, true)
    } else {
      this.status(STATUS.unsaved)
    }
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

// The form renders null as an empty field.
const sameAttrs = (a, b, kind) => FIELDS[kind].every((field) => (a[field] ?? "") === (b[field] ?? ""))

const clock = () => new Date().toLocaleTimeString([], {hour: "numeric", minute: "2-digit"})
