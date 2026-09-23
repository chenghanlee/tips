defmodule Tips.Content do
  @moduledoc """
  The Content context: tips, reviews, votes, media and search.

  ## Publication and edit contract

  These operations are reserved. They do not exist yet: #73 implements
  publication, #74 edits, #72 the comparator and #65 media claims. Their
  inputs and results are the types below.

    * `publish_tip(scope, submission_key, attrs, uploads)` returns
      `{:ok, t:publication_receipt/0}` or `{:error, t:publication_error/0}`.
    * `publish_review(scope, tip_id, submission_key, attrs, uploads)` returns
      the same.
    * `get_publication(scope, kind, submission_key, submitted_intent)` takes a
      `t:publication_kind/0` and a `t:intent/0` or `nil`, and returns
      `{:ok, t:publication_receipt/0 | nil}` or `{:error, t:lookup_error/0}`.
    * `get_edit_form(scope, kind, id)` returns `{:ok, t:edit_form/0}` or
      `{:error, :unauthenticated | :forbidden | :not_found}`.
    * `edit_tip(scope, id, expected_version, attrs, uploads)` returns
      `{:ok, t:edit_receipt/0}` or `{:error, t:edit_error/0}`.
    * `edit_review(scope, id, expected_version, attrs, uploads)` returns the
      same.

  ### Inputs

  The scope is the freshly admitted, server-built `Tips.Accounts.Scope` (see
  "Admission contract" in `Tips.Accounts`). Every other input is an explicit
  value: complete `t:attrs/0`, ids and page-owned files. No socket, LiveView
  upload entry, provider URL, bearer token or page-held R2 key enters Content.

  `uploads` is the entire ordered selection, as `t:attachment/0` values. `[]`
  means the author selected no attachments. A slot the page cannot resolve is
  `{:missing_image, slot}`, never left out. An image file's temporary path is
  valid only during the page attempt that owns it. Content uploads images and
  refreshes pending videos before its transaction; provider calls never run
  while database locks are held.

  Publication stores exactly the submitted setup. It never fills omitted or
  cleared review fields from the parent tip. It validates the tag, model and
  environment against active curated choices and returns unknown or retired
  ids as changeset errors, not database exceptions (#73 proves this against
  the actual foreign keys).

  ### Complete intent and comparison

  Content owns one whole-intent comparator, used both for same-key
  publication retries and for edit no-ops and conflict recovery. It returns
  `t:comparison/0`.

    * Text follows the changesets: a blank or whitespace-only value is an
      explicit blank (`nil`); every other value is compared verbatim,
      including surrounding whitespace, prompt/output indentation and the
      Unicode normalization form. An image description is blank-to-`nil` the
      same way.
    * Media compare by media id, position and description. A staged video's
      upload id is its media id, so it equals the same attached media.
    * Missing fields, a missing base, an absent selection (`nil`) and any
      `:missing_image` or `:image_file` slot make the result `:unknown`,
      whatever else differs. Filenames, slot ids and temporary paths never
      prove that bytes were saved. An edit that is not `:equivalent` is an
      actual change.
    * Counters, timestamps, versions and moderation state are not editable
      intent.

  ### Publication

  `:created` acknowledges the submitted values. For an existing key, Content
  compares the submitted intent with the current row only when the scope may
  read it (`Tips.Content.Visibility.decision/2` is `:visible`): hidden content
  under current author access compares; deleted content, identity-only
  lookup (`submitted_intent` is `nil`) and anything unreadable are
  `:existing_unknown`. Only `:created` and `:existing_equivalent` allow the
  editor to clear the submitted draft revision.

  A review's stored parent must match the submitted tip; otherwise the key
  names another publication and the result is `{:error, :conflict}`. A
  different key for an existing undeleted review is `{:error, :already_reviewed}`,
  decided only after the key lookup.

  `{:ok, nil}` from `get_publication/4` means no row is committed now. It is
  not proof that an earlier request rolled back; the author may retry with the
  same key. A lookup that cannot run returns `{:error, :outcome_unknown}`,
  never `{:ok, nil}`.

  Receipts carry identity and state, never content values, slugs or
  author-supplied redirect URLs. TipsWeb derives the destination from the
  current authorized projection: `/tips/:id/:slug` for a tip and
  `/reviews/:id` for a review.

  ### Editing

  `get_edit_form/3` reads the complete base, current attachments,
  `edit_version` and capability hints in one authorized snapshot. The editor
  keeps that version as its expected version until the author explicitly
  loads a newer one.

  An edit compares the expected version with the locked row first. A
  mismatch is `{:error, :conflict}` even when the editable values are equal.
  Ecto skips an update without changes, so `optimistic_lock/2` alone does not
  catch a stale no-op. At the current version, an unchanged whole intent is
  `:noop`: no version, date, search, media or notification change. An actual
  change advances `edit_version` once and returns `:updated` with the
  committed version.

  After a conflict, the editor compares its original base with the latest
  base. Only `:equivalent` offers an explicit save at the current version;
  `:different` or `:unknown` (including an incomplete base) needs manual
  reapply. An `:outcome_unknown` edit reloads saved state and keeps the input;
  never replay it with a freshly loaded version.

  ### Staged video handoff

  A publication-to-edit handoff may attach an owned, ready, unattached,
  unexpired video staged for `{:new_tip, key}` to `edit_tip` of the tip that
  the same author published with `key`, or one staged for
  `{:new_review, tip_id, key}` to `edit_review` of that author's review with
  `key` under `tip_id`. The claim resolves these immutable facts; it never
  rewrites the `Tips.Content.Media.Target`, rebinds media or edits a deleted
  original.

  ### Transaction participants

  Each row commits its effects together, in one transaction, or none of them.

  | Operation | `t:effect/0` values |
  |---|---|
  | New tip | `:content`, `:search_text`, `:self_vote`, `:media_claims` |
  | New review | the new-tip effects and `:review_notification` |
  | Same-key retry | none |
  | Actual edit | `:content_version`, `:search_text`, `:media_changes`, `:media_cleanup_jobs` |
  | No-op edit | none |

  `Tips.Content.Search` writers already require a caller transaction. A
  search or required notification failure rolls back the publication. The
  new-review notification folds only for a live review by someone other than
  the tip author. Edits keep votes and existing notification timestamps,
  counts and read state.
  """

  alias Tips.Accounts
  alias Tips.Content.Projection

  @typedoc "A content kind."
  @type kind :: :tip | :review

  @typedoc "What a submission key identifies: a tip, or a review of this tip."
  @type publication_kind :: :tip | {:review, tip_id :: pos_integer()}

  @typedoc "The author's key for one intended publication, kept with its draft."
  @type submission_key :: Ecto.UUID.t()

  @typedoc "A `media` row id: a saved attachment or a staged video upload."
  @type media_id :: pos_integer()

  @typedoc "The page's draft slot id for a new image. Feedback only, never identity."
  @type slot :: String.t()

  @typedoc "An image description; `nil` or blank means none. Videos have none."
  @type description :: String.t() | nil

  @typedoc "Every author-editable tip field. `nil` or blank is an explicit blank."
  @type tip_attrs :: %{
          title: String.t() | nil,
          body: String.t() | nil,
          tag_id: String.t() | nil,
          model_id: String.t() | nil,
          model_other: String.t() | nil,
          environment_id: String.t() | nil,
          prompt: String.t() | nil,
          output: String.t() | nil
        }

  @typedoc "Every author-editable review field. Reviews have no title or tag."
  @type review_attrs :: %{
          body: String.t() | nil,
          model_id: String.t() | nil,
          model_other: String.t() | nil,
          environment_id: String.t() | nil,
          prompt: String.t() | nil,
          output: String.t() | nil
        }

  @typedoc "Complete attrs for the operation's kind."
  @type attrs :: tip_attrs() | review_attrs()

  @typedoc "A new image/GIF file the page owns for this attempt."
  @type image_file :: %{path: Path.t(), filename: String.t()}

  @typedoc """
  One slot of the ordered selection:

    * `{:retained, media_id, description}` keeps a saved attachment (edits).
    * `{:staged_video, media_id}` selects the author's staged Tips video upload.
    * `{:image_file, slot, image_file, description}` adds a new image/GIF.
    * `{:missing_image, slot}` is a restored image slot awaiting reselection.
  """
  @type attachment ::
          {:retained, media_id(), description()}
          | {:staged_video, media_id()}
          | {:image_file, slot(), image_file(), description()}
          | {:missing_image, slot()}

  @typedoc "Which attachment an upload error names: a media id or an image slot."
  @type attachment_ref :: media_id() | slot()

  @typedoc """
  A complete editable intent: every field and the whole ordered selection.
  `uploads: nil` means the selection is unknown, not empty.
  """
  @type intent :: %{attrs: attrs(), uploads: [attachment()] | nil}

  @typedoc "Whether two intents save the same content."
  @type comparison :: :equivalent | :different | :unknown

  @typedoc "Stored state: live, hidden by moderators, or deleted by its author."
  @type content_state :: :live | :hidden | :deleted

  @typedoc "How a publication attempt relates to what its key committed."
  @type publication_outcome ::
          :created | :existing_equivalent | :existing_different | :existing_unknown

  @typedoc """
  The confirmed publication for a key. `tip_id` is the tip itself or the
  review's parent.
  """
  @type publication_receipt :: %{
          outcome: publication_outcome(),
          kind: kind(),
          id: pos_integer(),
          tip_id: pos_integer(),
          submission_key: submission_key(),
          state: content_state()
        }

  @typedoc """
  A rejected publication. Standard rejections and changesets come from
  `Tips.Accounts`; `:conflict` means the key names a review of another tip.
  """
  @type publication_error ::
          Accounts.operation_error()
          | :already_reviewed
          | {:upload_failed, [attachment_ref()]}
          | {:upload_pending, [media_id()]}
          | :outcome_unknown

  @typedoc "Why a publication lookup returned no answer."
  @type lookup_error :: :unauthenticated | :conflict | :outcome_unknown

  @typedoc """
  The editor's starting point from one authorized snapshot. `base` is the
  complete immutable editable intent with `:retained` media in order; `media`
  renders the current attachments.
  """
  @type edit_form :: %{
          kind: kind(),
          id: pos_integer(),
          tip_id: pos_integer(),
          edit_version: pos_integer(),
          state: :live | :hidden,
          base: intent(),
          media: [Projection.media_item()],
          capabilities: Projection.capabilities()
        }

  @typedoc "Whether a confirmed edit changed content."
  @type edit_outcome :: :updated | :noop

  @typedoc "A confirmed edit with the committed version and current state."
  @type edit_receipt :: %{
          outcome: edit_outcome(),
          kind: kind(),
          id: pos_integer(),
          tip_id: pos_integer(),
          edit_version: pos_integer(),
          state: :live | :hidden
        }

  @typedoc "A rejected edit. `:conflict` means a stale expected version."
  @type edit_error ::
          Accounts.operation_error()
          | {:upload_failed, [attachment_ref()]}
          | {:upload_pending, [media_id()]}
          | :outcome_unknown

  @typedoc "A database effect that commits with its operation. See the participant table."
  @type effect ::
          :content
          | :content_version
          | :search_text
          | :self_vote
          | :media_claims
          | :media_changes
          | :media_cleanup_jobs
          | :review_notification
end
