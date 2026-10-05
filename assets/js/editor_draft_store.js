// Browser draft storage for the tip and review editors: one IndexedDB record
// per account and form slot, guarded by its draft id and revision. Record
// shapes are declared in editor_contract.js; the rules are "Saving and
// recovery" in docs/design/frontend-design.md. No runtime imports.
//
// Every function resolves and never rejects:
//
//   {status: "ok", ...}         committed, or read
//   {status: "conflict"}        the stored draft is missing, replaced or newer
//   {status: "error", reason}   "invalid" arguments, "quota" exceeded,
//                               "unavailable" IndexedDB, or "failed"
//
// An error means the draft is not saved. The editor keeps its input and still
// lets the author publish; there is no other storage to fall back to. Storage
// never interprets publication receipts, merges or retries.

/** @typedef {import("./editor_contract.js").EditorStorageIdentity} EditorStorageIdentity */
/** @typedef {import("./editor_contract.js").EditorDraftPair} EditorDraftPair */
/** @typedef {import("./editor_contract.js").EditorRecord} EditorRecord */

/**
 * @typedef {{status: "conflict"}} DraftConflict
 * @typedef {{status: "error", reason: "invalid"|"quota"|"unavailable"|"failed"}} DraftError
 */

const DATABASE = "tips-editor-drafts"
const VERSION = 1
const STORE = "drafts"

const TIP_ATTRS = ["title", "body", "tag_id", "model_id", "model_other", "environment_id", "prompt", "output"]
const REVIEW_ATTRS = ["body", "model_id", "model_other", "environment_id", "prompt", "output"]

/**
 * Reads the draft stored in a slot.
 * @param {EditorStorageIdentity} storage
 * @returns {Promise<{status: "ok", record: EditorRecord|null}|DraftError>}
 */
export async function load(storage) {
  let key
  try {
    key = slotKey(copyStorage(storage))
  } catch {
    return invalid()
  }
  return transact("readonly", key, (_store, stored) => ({status: "ok", record: stored ?? null}))
}

/**
 * Explicitly creates a draft at revision 0 in an empty slot.
 * @param {EditorRecord} record
 * @returns {Promise<{status: "ok", record: EditorRecord}|DraftConflict|DraftError>}
 */
export async function create(record) {
  let next
  try {
    next = copyRecord(record)
    ensure(next.draft.revision === 0)
  } catch {
    return invalid()
  }
  const key = slotKey(next.storage)
  return transact("readwrite", key, (store, stored) => {
    if (stored !== undefined) return conflict()
    store.put(next, key)
    return {status: "ok", record: next}
  })
}

/**
 * Replaces the draft only while it still has the expected draft id and
 * revision, and advances the revision. The record keeps its storage and pair;
 * an explicit handoff may change its mode, target, base and expected version.
 * @param {EditorStorageIdentity} storage
 * @param {EditorDraftPair} expected
 * @param {EditorRecord} record
 * @returns {Promise<{status: "ok", record: EditorRecord}|DraftConflict|DraftError>}
 */
export async function save(storage, expected, record) {
  let next
  let pair
  try {
    const slot = copyStorage(storage)
    pair = copyPair(expected)
    next = copyRecord(record)
    ensure(same(next.storage, slot) && same(next.draft, pair))
    ensure(pair.revision < Number.MAX_SAFE_INTEGER)
    next.draft.revision = pair.revision + 1
  } catch {
    return invalid()
  }
  const key = slotKey(next.storage)
  return transact("readwrite", key, (store, stored) => {
    if (!holds(stored, pair)) return conflict()
    store.put(next, key)
    return {status: "ok", record: next}
  })
}

/**
 * Deletes the draft the author explicitly discarded, only while it still has
 * the expected draft id and revision.
 * @param {EditorStorageIdentity} storage
 * @param {EditorDraftPair} expected
 * @returns {Promise<{status: "ok"}|DraftConflict|DraftError>}
 */
export async function discard(storage, expected) {
  return remove(storage, expected)
}

/**
 * Deletes the submitted draft after its content was acknowledged, only while
 * it still has the submitted draft id and revision. Newer work stays.
 * @param {EditorStorageIdentity} storage
 * @param {EditorDraftPair} expected
 * @returns {Promise<{status: "ok"}|DraftConflict|DraftError>}
 */
export async function clear(storage, expected) {
  return remove(storage, expected)
}

async function remove(storage, expected) {
  let key
  let pair
  try {
    key = slotKey(copyStorage(storage))
    pair = copyPair(expected)
  } catch {
    return invalid()
  }
  return transact("readwrite", key, (store, stored) => {
    if (!holds(stored, pair)) return conflict()
    store.delete(key)
    return {status: "ok"}
  })
}

const holds = (stored, pair) =>
  stored !== undefined && stored.draft.draft_id === pair.draft_id && stored.draft.revision === pair.revision

const conflict = () => ({status: "conflict"})
const invalid = () => ({status: "error", reason: "invalid"})

function failure(error, reason) {
  return {status: "error", reason: error?.name === "QuotaExceededError" ? "quota" : reason}
}

// Reads the slot and decides in one transaction, and resolves only once that
// transaction has completed. An abort after a successful request is a failure.
function transact(mode, key, decide) {
  return connect().then(
    (db) =>
      new Promise((resolve) => {
        let transaction
        try {
          transaction = db.transaction(STORE, mode)
        } catch (error) {
          forget()
          resolve(failure(error, "failed"))
          return
        }
        let result
        const store = transaction.objectStore(STORE)
        const read = store.get(key)
        read.onsuccess = () => {
          result = decide(store, read.result)
        }
        transaction.oncomplete = () => resolve(result)
        transaction.onabort = () => resolve(failure(transaction.error, "failed"))
      }),
    (error) => failure(error, "unavailable"),
  )
}

// One connection per module instance. A failed open is not kept, so the next
// call tries again.
let connection = null

function connect() {
  connection ??= new Promise((resolve, reject) => {
    if (!globalThis.indexedDB) throw new Error("IndexedDB is unavailable")
    const request = globalThis.indexedDB.open(DATABASE, VERSION)
    request.onupgradeneeded = () => request.result.createObjectStore(STORE)
    request.onsuccess = () => {
      const db = request.result
      db.onversionchange = () => {
        db.close()
        forget()
      }
      db.onclose = forget
      resolve(db)
    }
    request.onerror = () => reject(request.error)
  }).catch((error) => {
    forget()
    throw error
  })
  return connection
}

function forget() {
  connection = null
}

function slotKey({account_id, slot}) {
  switch (slot.tag) {
    case "new_tip":
      return [account_id, "new_tip"]
    case "new_review":
      return [account_id, "new_review", slot.tip_id]
    case "edit":
      return [account_id, "edit", slot.kind, slot.id]
  }
}

// Validation copies arguments into fresh plain data before the first await, so
// later caller changes cannot reach a pending write and results never alias
// caller input. Unknown keys, binary and other non-plain values are rejected,
// never stripped. Text is kept exactly as typed; Content owns normalization.

function copyRecord(value) {
  fields(value, ["storage", "draft", "mode", "target", "submission_key", "intent", "base", "expected_version"])
  const storage = copyStorage(value.storage)
  const target = copyTarget(value.target)
  const kind = kindOf(target)
  ensure(kindOf(storage.slot) === kind)
  if (value.mode === "new") {
    ensure(target.tag !== "edit" && same(target, storage.slot))
  } else {
    ensure(value.mode === "edit" && target.tag === "edit")
    // An edit slot holds its own item; a new slot holds a handoff (K).
    ensure(storage.slot.tag !== "edit" || same(target, storage.slot))
  }
  const names = kind === "tip" ? TIP_ATTRS : REVIEW_ATTRS
  return {
    storage,
    draft: copyPair(value.draft),
    mode: value.mode,
    target,
    submission_key: value.submission_key === null ? null : nonEmpty(value.submission_key),
    intent: copyIntent(value.intent, names),
    base: value.base === null ? null : copyIntent(value.base, names),
    expected_version: value.expected_version === null ? null : positive(value.expected_version),
  }
}

function copyStorage(value) {
  fields(value, ["account_id", "slot"])
  return {account_id: positive(value.account_id), slot: copyTarget(value.slot)}
}

function copyPair(value) {
  fields(value, ["draft_id", "revision"])
  return {draft_id: nonEmpty(value.draft_id), revision: count(value.revision)}
}

function copyTarget(value) {
  switch (value?.tag) {
    case "new_tip":
      fields(value, ["tag"])
      return {tag: "new_tip"}
    case "new_review":
      fields(value, ["tag", "tip_id"])
      return {tag: "new_review", tip_id: positive(value.tip_id)}
    case "edit":
      fields(value, ["tag", "kind", "id"])
      ensure(value.kind === "tip" || value.kind === "review")
      return {tag: "edit", kind: value.kind, id: positive(value.id)}
    default:
      return ensure(false)
  }
}

function copyIntent(value, names) {
  fields(value, ["attrs", "uploads"])
  ensure(plain(value.attrs))
  const attrs = {}
  for (const [name, text] of Object.entries(value.attrs)) {
    ensure(names.includes(name))
    attrs[name] = optionalText(text)
  }
  if (value.uploads === null) return {attrs, uploads: null}
  ensure(Array.isArray(value.uploads))
  return {attrs, uploads: Array.from(value.uploads, copyMedia)}
}

function copyMedia(value) {
  switch (value?.tag) {
    case "retained":
      fields(value, ["tag", "media_id", "description"])
      return {tag: "retained", media_id: positive(value.media_id), description: optionalText(value.description)}
    case "staged_video":
      fields(value, ["tag", "media_id"])
      return {tag: "staged_video", media_id: positive(value.media_id)}
    case "missing_image":
      fields(value, ["tag", "slot", "filename", "type", "size", "description"])
      return {
        tag: "missing_image",
        slot: text(value.slot),
        filename: text(value.filename),
        type: text(value.type),
        size: count(value.size),
        description: optionalText(value.description),
      }
    default:
      return ensure(false)
  }
}

const NEW_KINDS = {new_tip: "tip", new_review: "review"}

const kindOf = (target) => (target.tag === "edit" ? target.kind : NEW_KINDS[target.tag])

// A plain object with exactly these keys.
function fields(value, keys) {
  ensure(plain(value))
  const own = Object.keys(value)
  ensure(own.length === keys.length && keys.every((key) => Object.hasOwn(value, key)))
}

function plain(value) {
  if (value === null || typeof value !== "object") return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

// Copies of plain data compare by their canonical JSON.
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

const text = (value) => (typeof value === "string" ? value : ensure(false))
const optionalText = (value) => (value === null ? null : text(value))
const nonEmpty = (value) => (text(value) !== "" ? value : ensure(false))
const count = (value) => (Number.isSafeInteger(value) && value >= 0 ? value : ensure(false))
const positive = (value) => (count(value) > 0 ? value : ensure(false))

function ensure(condition) {
  if (!condition) throw new TypeError("invalid draft argument")
}
