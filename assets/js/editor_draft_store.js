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

// Not implemented yet: every call reports an unsaved draft.
const unsaved = async () => ({status: "error", reason: "failed"})

/**
 * Reads the draft stored in a slot.
 * @param {EditorStorageIdentity} storage
 * @returns {Promise<{status: "ok", record: EditorRecord|null}|DraftError>}
 */
export async function load(storage) {
  return unsaved()
}

/**
 * Explicitly creates a draft at revision 0 in an empty slot.
 * @param {EditorRecord} record
 * @returns {Promise<{status: "ok", record: EditorRecord}|DraftConflict|DraftError>}
 */
export async function create(record) {
  return unsaved()
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
  return unsaved()
}

/**
 * Deletes the draft the author explicitly discarded, only while it still has
 * the expected draft id and revision.
 * @param {EditorStorageIdentity} storage
 * @param {EditorDraftPair} expected
 * @returns {Promise<{status: "ok"}|DraftConflict|DraftError>}
 */
export async function discard(storage, expected) {
  return unsaved()
}

/**
 * Deletes the submitted draft after its content was acknowledged, only while
 * it still has the submitted draft id and revision. Newer work stays.
 * @param {EditorStorageIdentity} storage
 * @param {EditorDraftPair} expected
 * @returns {Promise<{status: "ok"}|DraftConflict|DraftError>}
 */
export async function clear(storage, expected) {
  return unsaved()
}
