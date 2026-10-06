// Browser wire contract for the tip and review editors and their EditorDraft
// hook. Declarations only. The Elixir side and the rules live in
// TipsWeb.EditorContract (lib/tips_web/editor_contract.ex).
//
// JSON uses string keys, tagged objects for targets and media, and explicit
// nulls. Text travels exactly as typed; Content owns normalization.

/** Hook name registered by the editor page (#78). */
export const EDITOR_HOOK = "EditorDraft"

/**
 * Page events. restore: hook to LiveView, replied with EditorRestoreReply.
 * recover: form to LiveView through phx-auto-recover. reconcile: hook to
 * LiveView after a reconnect when a submission is unsettled, or the Check
 * again button. cleared: hook to LiveView with EditorClearResult. handoff,
 * clear, settled and refused: LiveView to hook; refused has an empty payload
 * and means a submit failed validation.
 */
export const EDITOR_EVENTS = Object.freeze({
  restore: "editor:restore",
  recover: "editor:recover",
  reconcile: "editor:reconcile",
  handoff: "editor:handoff",
  clear: "editor:clear",
  cleared: "editor:cleared",
  settled: "editor:settled",
  refused: "editor:refused",
})

/**
 * DOM declarations. The form and hook element id is
 * `editor-<account_id>-<tip|review>`; the hidden inputs mirror the data
 * attributes for LiveView form recovery.
 */
export const EDITOR_DOM = Object.freeze({
  identity: "data-editor-identity",
  record: "data-editor-record",
  identityInput: "editor[identity]",
  recordInput: "editor[record]",
})

/**
 * @typedef {Object} EditorNewTipTarget
 * @property {"new_tip"} tag
 */

/**
 * @typedef {Object} EditorNewReviewTarget
 * @property {"new_review"} tag
 * @property {number} tip_id
 */

/**
 * @typedef {Object} EditorEditTarget
 * @property {"edit"} tag
 * @property {"tip"|"review"} kind
 * @property {number} id
 */

/** @typedef {EditorNewTipTarget|EditorNewReviewTarget|EditorEditTarget} EditorTarget */

/**
 * Where a record is stored. Never authorization.
 * @typedef {Object} EditorStorageIdentity
 * @property {number} account_id
 * @property {EditorTarget} slot
 */

/**
 * The current account and logical form of a mounted editor.
 * @typedef {Object} EditorIdentity
 * @property {number} account_id
 * @property {EditorTarget} target
 */

/**
 * @typedef {Object} EditorDraftPair
 * @property {string} draft_id
 * @property {number} revision
 */

/**
 * @typedef {Object} EditorRetainedMedia
 * @property {"retained"} tag
 * @property {number} media_id
 * @property {string|null} description
 */

/**
 * @typedef {Object} EditorStagedVideo
 * @property {"staged_video"} tag
 * @property {number} media_id
 */

/**
 * An image whose file must be reselected. Filename, type and size are shown
 * to the author; they never prove saved bytes.
 * @typedef {Object} EditorMissingImage
 * @property {"missing_image"} tag
 * @property {string} slot
 * @property {string} filename
 * @property {string} type
 * @property {number} size
 * @property {string|null} description
 */

/** @typedef {EditorRetainedMedia|EditorStagedVideo|EditorMissingImage} EditorMedia */

/**
 * Every editable field of the kind, and the ordered selection or null when
 * unknown.
 * @typedef {Object} EditorIntent
 * @property {Object<string, string|null>} attrs
 * @property {EditorMedia[]|null} uploads
 */

/**
 * @typedef {Object} EditorRecord
 * @property {EditorStorageIdentity} storage
 * @property {EditorDraftPair} draft
 * @property {"new"|"edit"} mode
 * @property {EditorTarget} target
 * @property {string|null} submission_key
 * @property {EditorIntent} intent
 * @property {EditorIntent|null} base
 * @property {number|null} expected_version
 */

/**
 * @typedef {Object} EditorRestoreRequest
 * @property {EditorIdentity} identity
 * @property {EditorRecord} record
 */

/**
 * published: the record's publication is confirmed, so the page restored it
 * and the hook clears it; `to` is the item's path.
 * @typedef {Object} EditorRestoreReply
 * @property {"restored"|"published"|"rejected"} status
 * @property {EditorStorageIdentity} storage
 * @property {EditorDraftPair} draft
 * @property {string} [to]
 */

/**
 * @typedef {Object} EditorHandoff
 * @property {EditorStorageIdentity} storage
 * @property {EditorDraftPair} expected
 * @property {EditorRecord} record
 */

/**
 * An instruction to clear the revision that holds the submitted values, not
 * a result. The hook owns the revision; the page names the slot and draft,
 * and `to`, the confirmed item's path.
 * @typedef {Object} EditorClearRequest
 * @property {EditorStorageIdentity} storage
 * @property {string} draft_id
 * @property {string} to
 */

/**
 * ok: cleared. none: no revision of this page held the values. error: storage
 * failed. conflict: the slot holds other work, which stays. The page replies
 * {left: boolean}; unless it is leaving, the hook leaves for `to` itself.
 * @typedef {Object} EditorClearResult
 * @property {"ok"|"none"|"error"|"conflict"} status
 */

/**
 * @typedef {Object} EditorSettled
 * @property {boolean} unresolved
 */
