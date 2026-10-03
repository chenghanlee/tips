defmodule Tips.Content do
  @moduledoc """
  The Content context: tips, reviews, votes, media and search.

  ## Reading

  `get_tip_page/2` and `get_review_page/2` return the tip and selected-review
  destinations. Each takes a `t:viewer/0` and an id, and returns only
  `Tips.Content.Projection` output.

    * `nil` takes the public path: no token query and no privileged branch.
    * A `Tips.Accounts.SessionRef` is readmitted once, at entry, with
      `Tips.Accounts.readmit_scope/1`. Only the scope it returns reaches the
      projections, so current role, ban and confirmation decide the output, and
      a revoked or expired session fails even if its disconnect was lost.
      Anything else, including a `Tips.Accounts.Scope`, is
      `{:error, :unauthenticated}`. The reference comes from server-private
      state, never from request params, and is never returned or logged.
    * A malformed, out-of-range or missing id is `{:error, :not_found}`. An id
      may be an integer or its decimal string.

  A read that started before a revocation may finish.

  `get_review_page/2` reads the review first and uses its stored parent as tip
  context. It returns exactly that review or its removal notice; it takes no
  list filters, sort or page and never substitutes another review. Ranked
  review pages are later browse work.

  ## Publication and edit contract

  Publication and editing exist for text: `publish_tip/4`, `publish_review/5`,
  `get_publication/4`, `get_edit_form/3`, `edit_tip/5` and `edit_review/5`.
  Media claims and media edits (#65) are reserved and do not exist yet. Inputs
  and results are the types below. The comparator is `compare_intents/3`.

    * `publish_tip(scope, submission_key, attrs, uploads)` returns
      `{:ok, t:publication_receipt/0}` or `{:error, t:publication_error/0}`.
    * `publish_review(scope, tip_id, submission_key, attrs, uploads)` returns
      the same.
    * `get_publication(scope, kind, submission_key, submitted_intent)` takes a
      `t:publication_kind/0` and a `t:intent/0` or `nil`, and returns
      `{:ok, t:publication_receipt/0 | nil}` or `{:error, t:lookup_error/0}`.
    * `get_edit_form(scope, kind, id)` returns `{:ok, t:edit_form/0}` or
      `{:error, :unauthenticated | :not_found | :outcome_unknown}`.
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
  `{:missing_image, slot}`, never left out.

  A write needs complete, valid intent. Publication first looks up the key:
  an existing key returns its publication even for an incomplete recovered
  submission (usually `:existing_unknown`). Only a new write (absent key) and
  every edit then check completeness, before any provider work or
  transaction, and return `{:error, changeset}` without saving or dropping
  anything:

    * each missing editable field gets `{"is missing", [validation: :intent]}`;
      an explicit `nil` is a blank and gets ordinary required-field validation;
    * a missing or non-list `uploads` gets an `:uploads` error;
    * each `{:missing_image, slot}` gets an `:uploads` error with `slot: slot`
      in its metadata;
    * each `{:retained, media_id, _}` in a new publication gets an `:uploads`
      error with `media_id: media_id` in its metadata;
    * until #65 adds media claims, a new publication accepts only `uploads: []`:
      each `{:staged_video, media_id}` or `{:image_file, slot, _, _}` gets an
      `:uploads` error naming its media id or slot. Attachments are never
      dropped silently.

  An image file's temporary path is valid only during the page attempt that
  owns it. Content uploads images and refreshes pending videos before its
  transaction; provider calls never run while database locks are held.

  Publication stores exactly the submitted setup. It never fills omitted or
  cleared review fields from the parent tip. It validates the tag, model and
  environment against active curated choices and returns unknown or retired
  ids as changeset errors, not database exceptions: a retired id is "is not
  available"; an unknown id reaches the actual foreign key, which the
  changeset maps to "does not exist".

  ### Complete intent and comparison

  Content owns one whole-intent comparator, used both for same-key
  publication retries and for edit no-ops and conflict recovery. It returns
  `t:comparison/0`.

    * Text follows the changesets: a blank or whitespace-only value is an
      explicit blank (`nil`); every other value is compared verbatim,
      including surrounding whitespace, prompt/output indentation and the
      Unicode normalization form. An image description is blank-to-`nil` the
      same way. That description rule is declared here for #65/#72; `Asset`
      has no changeset yet, and `media_description_chk` rejects blank
      descriptions.
    * Media compare by media id, position and description. A staged video's
      upload id is its media id, so it equals the same attached media.
    * Missing fields, a missing base, an absent selection (`nil`) and any
      `:missing_image` or `:image_file` slot make the result `:unknown`,
      whatever else differs. Filenames, slot ids and temporary paths never
      prove that bytes were saved. For a complete, valid edit intent, anything
      other than `:equivalent` is an actual change; there only an
      `:image_file` makes the result `:unknown`. A missing field, selection
      or slot never authorizes a save.
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

  An existing key answers without write admission, validation or eligibility.
  An absent key first passes `Tips.AdmissionLimiter.check_write/2`; a denial
  returns `{:error, {:rate_limited, seconds}}` or `{:error, {:capacity, seconds}}`
  before any write, and a failed admitted write is not refunded. The
  transaction then locks the author (`:contribute` eligibility) and, for a
  review, its live parent tip; a missing, hidden or deleted parent is
  `{:error, :not_found}`. Last, it share-locks the selected curated choices
  and rechecks that they are active, so a retirement either waits for the
  commit or wins first and returns "is not available".

  A database error or lost connection during publication or lookup returns
  `{:error, :outcome_unknown}`: the author keeps the draft and checks the key.

  `{:ok, nil}` from `get_publication/4` means no row is committed now. It is
  not proof that an earlier request rolled back; the author may retry with the
  same key. A lookup that cannot run returns `{:error, :outcome_unknown}`,
  never `{:ok, nil}`.

  Receipts carry identity and state, never content values, slugs or
  author-supplied redirect URLs. TipsWeb derives the destination from the
  current authorized projection: `/tips/:id/:slug` for a tip and
  `/reviews/:id` for a review.

  ### Editing

  `get_edit_form/3` is a freshly admitted current-author read of undeleted
  content, hidden content included. It reads the account, complete base,
  current attachments, `edit_version` and capability hints in one statement.
  An unconfirmed or fully banned author still reads it, with
  `capabilities.edit == false`; the edit itself returns the Accounts
  eligibility error. Another account's or deleted content, and a malformed id,
  are `:not_found`; a deleted account is `:unauthenticated`. The editor keeps
  that version as its expected version until the author explicitly loads a
  newer one. The read consumes no write budget.

  An edit checks complete, valid intent first, as above: every field, a
  positive integer expected version (else an `:edit_version` error) and the
  selection as a proper list. Text that is not valid UTF-8 is "is invalid". It then passes `Tips.AdmissionLimiter.check_write/2`, with the
  same denials as publication. One transaction locks the author (`:contribute`
  eligibility) and the direct tip or review; a review edit takes no parent-tip
  lock, so a hidden or deleted parent does not block it. Missing, foreign or
  deleted content is `:not_found`.

  The expected version is compared with the locked row next. A mismatch is
  `{:error, :conflict}` even when the editable values are equal. Ecto skips an
  update without changes, so `optimistic_lock/2` alone does not catch a stale
  no-op. At the current version, an unchanged whole intent is `:noop`: no
  version, date, search, media or notification change. An actual change
  advances `edit_version` once, sets `edited_at`, rewrites the search text and
  returns `:updated` with the committed version. A newly selected curated
  choice must be active, as in publication; an unchanged retired choice stays.
  Publication dates, moderation state, votes, counters, rankings and
  notifications never change. Search text that comes out identical keeps its
  embedding.

  A failed eligibility, target or version guard rolls back. A fresh statement
  then reads the current account and target to name the rejection
  (`:unauthenticated`, `:unconfirmed`, `:forbidden`, `:not_found` or
  `:conflict`); if that read fails, the result is `:outcome_unknown`. The
  expected version is never replaced.

  Until media edits exist, `uploads` must be the saved selection unchanged, as
  `:retained` slots in order with equal descriptions (`[]` when there is
  none). Any other slot gets its publication `:uploads` error; a removal,
  reorder or description change gets "cannot be changed yet".

  After a conflict, the editor compares its original base with the latest
  base. Only `:equivalent` offers an explicit save at the current version;
  `:different` or `:unknown` (including an incomplete base) needs manual
  reapply. A database error or lost connection returns `:outcome_unknown`:
  the editor reloads saved state and keeps the input, and never replays it
  with a freshly loaded version.

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
  | Actual edit | `:content_version`, `:search_text`; with media edits, `:media_changes`, `:media_cleanup_jobs` |
  | No-op edit | none |

  `Tips.Content.Search` writers already require a caller transaction. A
  search or required notification failure rolls back the publication. The
  new-review notification folds only for a live review by someone other than
  the tip author. Edits keep votes and existing notification timestamps,
  counts and read state.
  """

  alias Tips.Accounts
  alias Tips.Accounts.Scope
  alias Tips.Content.{Edit, Intent, Projection, Publication, Read}

  @typedoc """
  Who reads: `nil` for an anonymous viewer, or the server-held reference to
  the session that admitted a signed-in one. See "Reading".
  """
  @type viewer :: Accounts.SessionRef.t() | nil

  @typedoc "The tip page: tip context and the viewer's own-review header link."
  @type tip_page :: %{tip: Projection.tip_detail(), own_review: Projection.own_review() | nil}

  @typedoc "Why a destination read returned nothing."
  @type read_error :: :unauthenticated | :not_found

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

    * `{:retained, media_id, description}` keeps a saved attachment (edits
      only; a new publication rejects it).
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
  Admission denials carry the whole seconds to wait.
  """
  @type publication_error ::
          Accounts.operation_error()
          | :already_reviewed
          | {:rate_limited | :capacity, retry_after_seconds :: pos_integer()}
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

  @typedoc """
  A rejected edit. `:conflict` means a stale expected version. Admission
  denials carry the whole seconds to wait.
  """
  @type edit_error ::
          Accounts.operation_error()
          | {:rate_limited | :capacity, retry_after_seconds :: pos_integer()}
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

  @doc """
  Compares two editable intents of one `kind`: a saved intent or edit base
  against a submitted one, or an editor's original base against the latest.

  Each side is a `t:intent/0`, possibly incomplete, or `nil`. Only the kind's
  editable fields and the ordered selection count; any other key is ignored.

    * `:equivalent`: both are complete and would save the same content.
    * `:different`: both are complete and at least one editable value differs.
    * `:unknown`: either side is `nil`, lacks a field or the selection, or has
      an `:image_file`, `:missing_image` or malformed value. This wins over
      any difference.

  This compares; it does not validate fields, check media ownership or
  authorize a write. See "Complete intent and comparison" above.

      iex> attrs = %{body: "Worked", model_id: nil, model_other: nil,
      ...>           environment_id: nil, prompt: " ", output: nil}
      iex> saved = %{attrs: %{attrs | prompt: nil}, uploads: [{:retained, 12, nil}]}
      iex> Tips.Content.compare_intents(:review, saved, %{attrs: attrs, uploads: [{:staged_video, 12}]})
      :equivalent
      iex> Tips.Content.compare_intents(:review, saved, %{attrs: attrs, uploads: []})
      :different
      iex> Tips.Content.compare_intents(:review, saved, %{attrs: attrs, uploads: nil})
      :unknown
  """
  @spec compare_intents(kind(), intent() | map() | nil, intent() | map() | nil) :: comparison()
  defdelegate compare_intents(kind, saved_or_base, submitted), to: Intent, as: :compare

  @doc """
  Publishes a new text tip for `submission_key`, or returns the publication
  the key already identifies. See "Publication" above.
  """
  @spec publish_tip(Scope.t() | nil, submission_key(), attrs(), [attachment()]) ::
          {:ok, publication_receipt()} | {:error, publication_error()}
  def publish_tip(scope, submission_key, attrs, uploads),
    do: Publication.publish(scope, :tip, submission_key, attrs, uploads)

  @doc """
  Publishes a new text review of `tip_id` for `submission_key`, or returns the
  publication the key already identifies. See "Publication" above.
  """
  @spec publish_review(Scope.t() | nil, pos_integer(), submission_key(), attrs(), [attachment()]) ::
          {:ok, publication_receipt()} | {:error, publication_error()}
  def publish_review(scope, tip_id, submission_key, attrs, uploads),
    do: Publication.publish(scope, {:review, tip_id}, submission_key, attrs, uploads)

  @doc """
  Returns the author's publication for `submission_key`, compared with
  `submitted_intent` (`nil` for identity only), or `{:ok, nil}` when no row is
  committed now. Consumes no write budget.
  """
  @spec get_publication(Scope.t() | nil, publication_kind(), submission_key(), intent() | nil) ::
          {:ok, publication_receipt() | nil} | {:error, lookup_error()}
  defdelegate get_publication(scope, kind, submission_key, submitted_intent),
    to: Publication,
    as: :get

  @doc """
  Reads the author's editable snapshot of a tip or review. See "Editing".
  """
  @spec get_edit_form(Scope.t() | nil, kind(), term()) ::
          {:ok, edit_form()} | {:error, :unauthenticated | :not_found | :outcome_unknown}
  defdelegate get_edit_form(scope, kind, id), to: Edit, as: :get_form

  @doc """
  Saves one complete text edit of the author's tip against `expected_version`.
  See "Editing".
  """
  @spec edit_tip(Scope.t() | nil, pos_integer(), pos_integer(), attrs(), [attachment()]) ::
          {:ok, edit_receipt()} | {:error, edit_error()}
  def edit_tip(scope, id, expected_version, attrs, uploads),
    do: Edit.edit(scope, :tip, id, expected_version, attrs, uploads)

  @doc """
  Saves one complete text edit of the author's review against
  `expected_version`. See "Editing".
  """
  @spec edit_review(Scope.t() | nil, pos_integer(), pos_integer(), attrs(), [attachment()]) ::
          {:ok, edit_receipt()} | {:error, edit_error()}
  def edit_review(scope, id, expected_version, attrs, uploads),
    do: Edit.edit(scope, :review, id, expected_version, attrs, uploads)

  @doc """
  Reads the tip page for `viewer`: the projected tip, deleted or removed tips
  as placeholders, and the viewer's own undeleted review as an id and current
  capabilities, even under an unavailable tip. See "Reading".
  """
  @spec get_tip_page(viewer(), term()) :: {:ok, tip_page()} | {:error, read_error()}
  defdelegate get_tip_page(viewer, tip_id), to: Read

  @doc """
  Reads the selected-review destination (`/reviews/:id`) for `viewer`: the
  review's own tip as context and that review, or its removal notice. See
  "Reading".
  """
  @spec get_review_page(viewer(), term()) ::
          {:ok, Projection.selected_review()} | {:error, read_error()}
  defdelegate get_review_page(viewer, review_id), to: Read
end
