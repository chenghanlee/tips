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
 * recover: form to LiveView through phx-auto-recover. handoff and clear:
 * LiveView to hook.
 */
export const EDITOR_EVENTS = Object.freeze({
  restore: "editor:restore",
  recover: "editor:recover",
  handoff: "editor:handoff",
  clear: "editor:clear",
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
 * @typedef {Object} EditorRestoreReply
 * @property {"restored"|"preserved"|"rejected"} status
 * @property {EditorStorageIdentity} storage
 * @property {EditorDraftPair} draft
 */

/**
 * @typedef {Object} EditorHandoff
 * @property {EditorStorageIdentity} storage
 * @property {EditorDraftPair} expected
 * @property {EditorRecord} record
 */

/**
 * @typedef {Object} EditorSubmittedDraft
 * @property {EditorStorageIdentity} storage
 * @property {EditorDraftPair} draft
 * @property {EditorTarget} target
 */

/**
 * @typedef {Object} EditorPublicationReceipt
 * @property {"created"|"existing_equivalent"} outcome
 * @property {"tip"|"review"} kind
 * @property {number} id
 * @property {number} tip_id
 * @property {string} submission_key
 * @property {"live"|"hidden"|"deleted"} state
 */

/**
 * @typedef {Object} EditorEditReceipt
 * @property {"updated"|"noop"} outcome
 * @property {"tip"|"review"} kind
 * @property {number} id
 * @property {number} tip_id
 * @property {number} edit_version
 * @property {"live"|"hidden"} state
 */

/**
 * An instruction to clear exactly the submitted draft pair, not a result.
 * @typedef {Object} EditorClearRequest
 * @property {EditorSubmittedDraft} submitted
 * @property {EditorPublicationReceipt|EditorEditReceipt} receipt
 */
