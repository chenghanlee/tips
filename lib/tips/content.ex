defmodule Tips.Content do
  @moduledoc """
  The Content context: tips, reviews, votes, reports, media and search.

  ## Reading

  `get_tip_page/3` and `get_review_page/2` return the tip and selected-review
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
  list filters, sort or page and never substitutes another review.

  `get_tip_page/3` also returns `reviews: %{entries: [review], has_more:
  boolean}`: at most 30 live reviews, each a
  `t:Tips.Content.Projection.visible_review/0`, and whether a 31st exists.
  It lists them under a deleted or hidden tip too. The viewer's own live
  review keeps its rank; a hidden one is reached through `own_review`.
  Options:

    * `:sort` - `:best` (default) orders by best score, `:new` by creation
      time; both break ties by the higher id. Edits never move a review.
    * `:offset` - a multiple of 30, default 0. There is no last page.
    * `:model_id`, `:environment_id` - exact matches on the reviewer's
      setup, combined with AND. A review that reported no setup, or a
      free-text model, never matches. An unset filter adds no condition.

  A malformed option is `{:error, :invalid_option}`.

  ### Browsing

  `list_tips/2` returns one page of the shared Hot or New feed. Like search,
  it lists only live tips for every viewer, authors and moderators included;
  the scope only sets each row's vote and capability hints. Options:

    * `:sort` - `:hot` (default) orders by hot score, `:new` by creation
      time; both break ties by the higher id.
    * `:offset` - a multiple of 20, default 0. There is no last page.
    * `:tag_id`, `:model_id`, `:environment_id` - exact matches on the tip
      author's setup, combined with AND. A review's setup never matches, and
      neither does a free-text model. An unset filter adds no condition.

  The result is `{:ok, %{entries: [summary], has_more: boolean}}`: at most
  20 `t:Tips.Content.Projection.summary/0` rows, and whether a 21st row
  exists. No total is counted. Each call reads the current ranking, so
  consecutive pages can repeat or skip a tip whose rank changed. A malformed
  option is `{:error, :invalid_option}`.

  ### Inbox

  `get_inbox(viewer, opts)` reads one page of the viewer's notifications,
  newest activity first (`updated_at`, then the higher id). It readmits the
  session like the readers above; `nil` or a revoked session is
  `{:error, :unauthenticated}`. Options:

    * `:offset` - a multiple of 20, default 0. There is no last page.
    * `:mark_read` - `true` once per connected inbox visit, default `false`.

  The page, its targets and, with `:mark_read`, every unread `(id, count)`
  pair of the account come from one repeatable-read, read-only snapshot,
  including rows on other pages. The page shows the snapshot, so a marking
  visit renders its rows unread. A separate update then sets `read_at` only
  on captured rows still unread at their captured count: a fold or new row
  committed after the snapshot stays unread. Marking changes no time, count or
  order. A malformed option is `{:error, :invalid_option}`.

  Each entry is a `t:Tips.Content.Projection.inbox_entry/0`: the target tip
  through the deletion-first projection, never a raw joined title, and the
  reviewer's handle on a review notification only while the viewer may read
  that review. Vote rows name no voter and carry no event count.

  `count_unread_notifications(scope)` is the unread badge for a freshly
  admitted scope, capped at 100.

  ## Publication and edit contract

  Publication exists for text: `publish_tip/4`, `publish_review/5` and
  `get_publication/4`. Text edits exist: `get_edit_form/3`, `edit_tip/5` and
  `edit_review/5`. Editors check typed text with `change_content/2`, which
  writes nothing. Publications and edits claim staged videos and attach new
  image files. Inputs and results are the types below. The
  comparator is `compare_intents/3`.

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
    * a selection over ten slots gets an `:uploads` error, and a media id
      selected more than once gets one naming it;
    * a malformed entry gets an `:uploads` error. Attachments are never
      dropped silently.

  Each `{:image_file, slot, image_file, description}` is then stored by
  `Tips.Content.Media.store_images/2`, after admission and validation and
  before the transaction. A file it rejects or cannot store is an `:uploads`
  error with `slot: slot` in its metadata: larger than 10 MB, not a PNG,
  JPEG, WebP or GIF, unreadable as an image, a failed upload, or no parser
  free; new files over 50 MB together name the first image slot. A
  transaction known to have rolled back deletes the images its attempt
  stored; `{:error, :outcome_unknown}` deletes nothing and leaves them to the
  orphan sweep. A retry stores the page's files again under new keys.

  An image file's temporary path is valid only during the page attempt that
  owns it. Content uploads images with `Tips.Content.Media.store_images/2` and
  refreshes pending videos before its transaction; provider calls never run
  while database locks are held.

  ### Staged video claims

  Each `{:staged_video, media_id}` is claimed inside the content transaction
  from committed state: the author's unattached, ready video, not in cleanup
  and before its deadline by wall time after any lock wait, whose stored
  target is the item's own: the publication's `{:new_tip, key}` or
  `{:new_review, tip_id, key}`, or an edit's `{:edit_tip, id}` or
  `{:edit_review, id}` (or the original publication's, see "Staged video
  handoff"). Possessing an id or key grants nothing. Any other id, including
  another author's, an attached or an expired one, is
  `{:error, {:upload_failed, [media_id]}}`; otherwise a video still uploading
  or processing is `{:error, {:upload_pending, [media_id]}}`. Either rejects
  the whole publication or edit, which writes nothing and leaves every staged
  video reusable. A commit attaches each video once at its index in the
  selection, clears its expiry and cooldown and keeps its target. Media row
  locks follow the account, content and curated-choice locks, in ascending
  id; claims and cleanup of a row serialize on its lock (see
  "Claims" in `Tips.Content.Media`).

  Publication stores exactly the submitted setup. It never fills omitted or
  cleared review fields from the parent tip. It validates the tag, model and
  environment against active curated choices and returns unknown or retired
  ids as changeset errors, not database exceptions: a retired id is "is not
  available"; an unknown id reaches the actual foreign key, which the
  changeset maps to "does not exist".

  A new or edited tip or review whose search document would exceed 30,000
  UTF-8 bytes is not saved and returns `{:error, {:too_long, words}}`, where
  `words` is about how many words to remove (see "Documents" in
  `Tips.Content.Search`). The fields are each within their own limits; only
  their combined size, measured in the content transaction, is over.

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
  content. It reads the complete base, current attachments, `edit_version`
  and capability hints in one snapshot. An unconfirmed or fully banned author
  still reads it, with `capabilities.edit == false`; the edit itself returns
  the Accounts eligibility error. Another account's or deleted content is
  `:not_found`. Its `id` takes the readers' integer or decimal-string forms;
  an edit takes an integer id. The editor keeps that version as its expected
  version until the author explicitly loads a newer one. A read that cannot
  run returns `{:error, :outcome_unknown}`.

  An edit checks the scope, then passes `Tips.AdmissionLimiter.check_write/2`
  like a new publication: every attempt, including an invalid, no-op or
  conflicting one, spends one write and is not refunded. It then checks
  complete intent (see above) and a positive integer `expected_version`
  (otherwise an `:edit_version` error). Edits may keep, remove and add
  attachments: the `{:retained, id, description}` entries of `uploads` must
  keep the current list's relative order and descriptions, with staged videos
  and image files anywhere among them. A current attachment left out, or all
  of them with `[]`, is removed: the edit retires it with
  `Tips.Content.Media.retire/1` after the version write and before the claim.
  A missing image is an `:uploads` error before the transaction; a reordered
  or redescribed attachment, or a retained id not attached here, is an
  `:uploads` error naming its media id where one exists. A staged video
  that is not claimable rejects the edit (see "Staged video claims"). Only a
  newly selected curated choice must be active; a saved retired choice may
  stay.

  The transaction locks the author, then the content row, and checks
  `:contribute` eligibility, ownership and deletion (`:not_found`). A failed
  guard rolls back, and fresh reads then return the current eligibility
  error, `:not_found`, or `:conflict` when the author may still edit. A
  review edit never locks its parent, which may be hidden or deleted. An
  edit keeps `dead_at`, publication time, submission key, votes, counters and
  notifications. It rewrites search text only when the search document
  changes; an unchanged document keeps its embedding.

  An edit compares the expected version with the locked row first. A
  mismatch is `{:error, :conflict}` even when the editable values are equal.
  Ecto skips an update without changes, so `optimistic_lock/2` alone does not
  catch a stale no-op. At the current version, an unchanged whole intent is
  `:noop`: no version, date, search, media or notification change. An actual
  change, including an added staged video, advances `edit_version` once and
  returns `:updated` with the committed version. The version check precedes
  any claim, so a stale edit claims nothing.

  After a conflict, the editor compares its original base with the latest
  base. Only `:equivalent` offers an explicit save at the current version;
  `:different` or `:unknown` (including an incomplete base) needs manual
  reapply. An `:outcome_unknown` edit reloads saved state and keeps the input;
  never replay it with a freshly loaded version.

  ### Video upload

  `begin_video_upload(scope, target, file_attrs)` reserves one private Stream
  upload for a video the author selected, before publication. It returns
  `{:ok, t:Tips.Content.Media.video_upload/0}` or
  `{:error, t:video_upload_error/0}`. The browser sends the bytes directly to
  `upload_url` by tus until `expires_at`, one hour after the reservation;
  `media_id` is the `{:staged_video, media_id}` the draft keeps. The steps
  and row states are in `Tips.Content.Media`.

    * `target` is the server-built `t:Tips.Content.Media.Target.t/0` tuple.
      `Tips.Content.Media.Target` is the only encoding; a string or any other
      shape is a `:target` changeset error.
    * `file_attrs` is read for `size` only, the declared byte length, which
      must be 1 to 1,000,000,000. Everything else, such as a uid, account id
      or target, is ignored.

  The checks run in this order, each before any later work:

    1. A missing scope is `:unauthenticated`; invalid input is a changeset.
    2. For a new-submission target, a key this author already published is
       `{:published, t:publication_receipt/0}` (any state, deleted
       included): the draft continues as an edit of that publication. A
       review key under another tip is `:conflict`.
    3. One `Tips.AdmissionLimiter.check_upload/2`, never refunded.
    4. One transaction locks the author (`:contribute` eligibility), then
       share-locks the target: a new review needs a live parent tip; an edit
       needs the author's own undeleted tip or review, which may be hidden.
       Anything else is `:not_found`.

  Selecting a file writes only the media row: no content, vote,
  notification, report or search row. `{:upload_failed, [media_id]}` means
  no URL was released for that row, and a fresh upload is needed; it
  covers a rejected reservation, a lost response and a response after the
  deadline or cleanup. A database error is `:outcome_unknown`; no URL was
  returned either.

  ### Video status

  `get_video_uploads(scope, upload_ids)` refreshes up to ten of the author's
  video uploads from Stream and returns each one's committed state, in the
  given order, as `t:Tips.Content.Media.video_status/0`. The editor calls it
  from page-owned async work and schedules the next call itself. It never
  publishes, attaches or transfers media, and browser progress never
  declares readiness. The checks run in this order, each before any provider
  request:

    1. A missing scope is `:unauthenticated`. `upload_ids` must be a list of
       at most ten distinct media ids, or it is a changeset.
    2. The account must still have `:contribute` eligibility.
    3. Every id must be one of the author's videos, and each upload's target
       must still be valid as in "Video upload" step 4. Otherwise the whole
       call is `:not_found`.

  Only unattached, known-uid uploads that are `uploading` or `processing`
  and not in cleanup are read; ready, failed, attached and removed uploads
  need no request. The reads and the guarded state changes are in
  `Tips.Content.Media`; the deadlines follow "Video states and deadlines" in
  the data model. A timed-out or failed read leaves the upload's state as it
  was, with `refresh: :uncertain`: still checking, not failed. A database
  error is `:outcome_unknown`.

  ### Staged video handoff

  A publication-to-edit handoff may attach an owned, ready, unattached,
  unexpired video staged for `{:new_tip, key}` to `edit_tip` of the tip that
  the same author published with `key`, or one staged for
  `{:new_review, tip_id, key}` to `edit_review` of that author's review with
  `key` under `tip_id`. The claim resolves these immutable facts; it never
  rewrites the `Tips.Content.Media.Target`, rebinds media or edits a deleted
  original. The edit's own expected-version check still applies first.

  ### Deletion and moderation

  `delete_content(scope, kind, id)` irreversibly deletes the author's own tip
  or review. `get_moderation_case(session_ref, kind, id)` reads one case;
  `hide_content/5` and `restore_content/5` change only moderator visibility
  (`dead_at`) against what the moderator reviewed. Successes return
  `t:lifecycle_receipt/0`; raw rows never leave Content.

  Each mutation checks the scope, spends one `Tips.AdmissionLimiter.check_write/2`
  (rejected, conflicting and unchanged attempts included, never refunded),
  validates its input, then takes locks in the shared order: the acting
  account, the tip, then the review. A review always locks its parent tip
  first, even a hidden or deleted one, because the review-count trigger
  writes it. Eligibility is rechecked on the locked account.

  Deletion uses `:delete_own_content`, so unconfirmed and fully banned authors
  may delete. Another author's or a missing row is `:not_found`; an owned,
  already-deleted row is `:unchanged` with no further effects. A real
  deletion sets `deleted_at` and advances `edit_version` once, keeping
  `dead_at` and author dates; marks the row's own attached media for cleanup
  and enqueues its provider deletion (`Tips.Content.Media.retire/1`); resolves
  the target's open reports with no resolver; and removes, read or unread, a
  review's notifications, or a tip's `tip_upvoted` notifications and the
  `tip_reviewed` notifications of its reviews. Reviews, their media and
  review-upvote notifications stay.
  Errors: `t:delete_error/0`.

  The case read readmits the session and requires the moderator role only: a
  full ban or missing confirmation still reads. It is one repeatable-read
  snapshot of the projected content (deletion-first, as for every viewer), its
  version and state, and the open reports without reporter identity. Errors:
  `:unauthenticated`, `:forbidden`, `:not_found`, `:outcome_unknown`. An id may
  be an integer or its decimal string; mutations take an integer.

  Hide and restore require `:moderate` eligibility. `expected_version` must be
  a positive integer and `reviewed_report_ids` a list of unique positive ids
  (`[]` allowed); otherwise a changeset. Deleted content, a different version,
  or any reviewed id that is missing, another target's or already resolved is
  `{:error, {:conflict, case}}` with a fresh case read after rollback; reports
  filed later are not compared. Only after all guards does an already-hidden
  hide or already-live restore return `:unchanged`, resolving nothing. A real
  change sets or clears `dead_at` and advances `edit_version` once; hide
  resolves exactly the reviewed reports with the moderator as resolver, and
  restore leaves them open. Author dates, text, votes, search data, media and
  notifications are kept; nothing is replayed. Errors:
  `t:moderation_error/0`.

  A database error or lost connection returns `{:error, :outcome_unknown}`;
  reload before deciding to repeat.

  ### Voting

  `set_vote(scope, kind, id, desired)` sets the scope's vote on a tip or review
  to Helpful (`1`), Not helpful (`-1`) or no vote (`nil`). It sends the wanted
  state, not a toggle, so a retried request cannot reverse itself. It returns
  `{:ok, t:vote_receipt/0}` or `{:error, t:vote_error/0}`.

  A vote checks the scope and spends one `Tips.AdmissionLimiter.check_write/2`,
  like the other writes. The transaction locks the voter's account
  (`:contribute` eligibility), then only the voted tip or review: a review vote
  never locks its parent, and a review under a hidden or deleted tip still
  takes votes. A missing, hidden or deleted target is `{:error, :not_found}`
  for every voter, author included; the vote capability is false there too. A
  hide, deletion or ban that commits first therefore rejects the vote; one that
  waits sees the committed vote.

  A request that matches the stored vote is `:unchanged` and writes nothing.
  A rejection is always an error, never `:unchanged`. A real change writes or
  removes the vote row once; the counter trigger updates the target, never its
  `edit_version`. Each change to Helpful is one helpful-vote event and folds
  the author's `tip_upvoted` or `review_upvoted` notification: voting, removing
  and voting again counts twice, and so does Not helpful then Helpful. The
  author's own vote notifies no one. The receipt's counters and score are read
  under the target lock after the write, not derived from a delta.

  Lifting a ban never recreates votes that invalidation removed; a later
  explicit vote is a new event. A database error or lost connection returns
  `{:error, :outcome_unknown}`: read the current vote before offering another
  change.

  ### Reporting

  `report_content(scope, kind, id, attrs)` stores the scope's report of a
  suspected rule violation on a tip or review. `attrs` takes `reason`
  (`spam`, `harmful`, `fabricated` or `other`; `fabricated` means suspected
  invented experience or evidence) and an optional `detail` of at most 1000
  characters; a blank detail is stored as `nil`. Malformed input is a
  changeset.

  A report checks the scope and spends one `Tips.AdmissionLimiter.check_write/2`,
  like the other writes. The transaction locks the reporter's account
  (`:contribute` eligibility), then only the reported tip or review `FOR SHARE`:
  a review report never locks its parent. A missing, hidden or deleted target
  is `{:error, :not_found}`. An author deletion that commits first therefore
  rejects the report; one that waits resolves it.

  Each reporter has at most one open report per target. `{:ok,
  t:report_receipt/0}` comes only after confirmed persistence: `:stored` for
  the new report, or `:already_open` with the earlier open report's id when
  one exists. `:already_open` stores nothing, so the submitted reason and
  detail were not saved. After the earlier report is resolved, a new report
  is allowed on unchanged content. If that report is resolved while the
  receipt is read, or a database error or lost connection occurs, the result
  is `{:error, :outcome_unknown}`: keep the input and let the reporter submit
  again explicitly. Nothing retries automatically.

  A report changes no visibility, version, counter, vote, ranking, account or
  notification.

  ### Transaction participants

  Each row commits its effects together, in one transaction, or none of them.

  | Operation | `t:effect/0` values |
  |---|---|
  | New tip | `:content`, `:search_text`, `:self_vote`, `:media_claims` |
  | New review | the new-tip effects and `:review_notification` |
  | Same-key retry | none |
  | Actual edit | `:content_version`, `:search_text`, `:media_changes`, `:media_cleanup_jobs` |
  | No-op edit | none |
  | Author deletion | `:content_version`, `:report_resolution`, `:notification_removal`, `:media_changes`, `:media_cleanup_jobs` |
  | Hide | `:content_version`, `:report_resolution` |
  | Restore | `:content_version` |
  | Unchanged deletion, hide or restore | none |
  | Vote change | `:vote`, `:vote_notification` |
  | Unchanged vote | none |
  | New report | `:report` |
  | Already open report | none |

  `Tips.Content.Search` writers already require a caller transaction. A
  search or required notification failure rolls back the publication. The
  new-review notification folds only for a live review by someone other than
  the tip author. Edits keep votes and existing notification timestamps,
  counts and read state.
  """

  alias Tips.Accounts
  alias Tips.Accounts.Scope

  alias Tips.Content.{
    Browse,
    Deletion,
    Edit,
    Intent,
    Media,
    Moderation,
    Notification,
    Projection,
    Publication,
    Read,
    Review,
    Search,
    Tip,
    Vocabulary,
    Voting
  }

  @typedoc """
  Who reads: `nil` for an anonymous viewer, or the server-held reference to
  the session that admitted a signed-in one. See "Reading".
  """
  @type viewer :: Accounts.SessionRef.t() | nil

  @typedoc "The tip page: tip context, the viewer's own-review header link and a review page."
  @type tip_page :: %{
          tip: Projection.tip_detail(),
          own_review: Projection.own_review() | nil,
          reviews: Read.reviews()
        }

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
          | Search.too_long()
          | :outcome_unknown

  @typedoc "Why a publication lookup returned no answer."
  @type lookup_error :: :unauthenticated | :conflict | :outcome_unknown

  @typedoc "Why no upload URL was returned. See \"Video upload\"."
  @type video_upload_error ::
          Accounts.operation_error()
          | {:published, publication_receipt()}
          | {:rate_limited | :capacity, retry_after_seconds :: pos_integer()}
          | {:upload_failed, [media_id()]}
          | :outcome_unknown

  @typedoc "Why no upload states were returned. See \"Video status\"."
  @type video_status_error :: Accounts.operation_error() | :outcome_unknown

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
          | Search.too_long()
          | :outcome_unknown

  @typedoc "A confirmed deletion, hide or restore with the committed version and state."
  @type lifecycle_receipt :: %{
          kind: kind(),
          id: pos_integer(),
          tip_id: pos_integer(),
          state: :live | :hidden | :deleted,
          edit_version: pos_integer(),
          outcome: :changed | :unchanged
        }

  @typedoc "A rejected author deletion. See \"Deletion and moderation\"."
  @type delete_error ::
          :unauthenticated
          | :not_found
          | {:rate_limited | :capacity, retry_after_seconds :: pos_integer()}
          | :outcome_unknown

  @typedoc "One open report in a moderation case. Reporter identity is never included."
  @type report :: %{
          id: pos_integer(),
          reason: :spam | :harmful | :fabricated | :other,
          detail: String.t() | nil,
          created_at: DateTime.t()
        }

  @typedoc """
  A moderation case: identity, current state and version, the moderator's
  projection of the content and its open reports, oldest first.
  """
  @type moderation_case :: %{
          kind: kind(),
          id: pos_integer(),
          tip_id: pos_integer(),
          state: :live | :hidden | :deleted,
          edit_version: pos_integer(),
          content: Projection.tip_detail() | Projection.review_view(),
          reports: [report()]
        }

  @typedoc """
  A rejected hide or restore. `{:conflict, case}` carries the current case to
  review again. Malformed input is a changeset.
  """
  @type moderation_error ::
          :unauthenticated
          | :unconfirmed
          | :forbidden
          | :not_found
          | {:conflict, moderation_case()}
          | Ecto.Changeset.t()
          | {:rate_limited | :capacity, retry_after_seconds :: pos_integer()}
          | :outcome_unknown

  @typedoc """
  A confirmed report on the target `kind` and `id`. `report_id` is the new
  report for `:stored` and the earlier open one for `:already_open`. See
  "Reporting".
  """
  @type report_receipt :: %{
          kind: kind(),
          id: pos_integer(),
          report_id: pos_integer(),
          outcome: :stored | :already_open
        }

  @typedoc "A rejected or uncertain report. Malformed input is a changeset. See \"Reporting\"."
  @type report_error ::
          :unauthenticated
          | :unconfirmed
          | :forbidden
          | :not_found
          | Ecto.Changeset.t()
          | {:rate_limited | :capacity, retry_after_seconds :: pos_integer()}
          | :outcome_unknown

  @typedoc "A desired vote: Helpful (`1`), Not helpful (`-1`) or none (`nil`)."
  @type vote :: Projection.vote()

  @typedoc """
  The confirmed vote and the target's counters after it. `score` is
  `up_count - down_count`. See "Voting".
  """
  @type vote_receipt :: %{
          kind: kind(),
          id: pos_integer(),
          vote: vote(),
          up_count: non_neg_integer(),
          down_count: non_neg_integer(),
          score: integer(),
          outcome: :changed | :unchanged
        }

  @typedoc "A rejected vote. See \"Voting\"."
  @type vote_error ::
          :unauthenticated
          | :unconfirmed
          | :forbidden
          | :not_found
          | {:rate_limited | :capacity, retry_after_seconds :: pos_integer()}
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
          | :report_resolution
          | :notification_removal
          | :vote
          | :vote_notification
          | :report

  @doc """
  Checks a form's author-editable text with the rules a publication or edit
  applies, without writing or authorizing anything. Returns the changeset
  with action `:validate`; its errors name only `kind`'s editable fields.
  The submission key and parent come from the write, and curated choices are
  checked only by it.
  """
  @spec change_content(kind(), map()) :: Ecto.Changeset.t()
  def change_content(kind, attrs) do
    fields = Intent.fields(kind)
    changeset = content_changeset(kind, Map.take(attrs, fields))
    errors = Keyword.take(changeset.errors, fields)
    %{changeset | errors: errors, valid?: errors == [], action: :validate}
  end

  defp content_changeset(:tip, attrs), do: Tip.changeset(%Tip{}, attrs)
  defp content_changeset(:review, attrs), do: Review.changeset(%Review{}, attrs)

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
  Reserves a private Stream upload of one video for `target`. See
  "Video upload" above.
  """
  @spec begin_video_upload(Scope.t() | nil, Media.Target.t(), %{size: pos_integer()}) ::
          {:ok, Media.video_upload()} | {:error, video_upload_error()}
  def begin_video_upload(scope, target, file_attrs),
    do: Media.begin_video_upload(scope, target, file_attrs)

  @doc """
  Refreshes the author's selected video uploads. See "Video status" above.
  """
  @spec get_video_uploads(Scope.t() | nil, [media_id()]) ::
          {:ok, [Media.video_status()]} | {:error, video_status_error()}
  def get_video_uploads(scope, upload_ids), do: Media.get_video_uploads(scope, upload_ids)

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
  as placeholders, the viewer's own undeleted review as an id and current
  capabilities, even under an unavailable tip, and one ranked page of live
  reviews. See "Reading".
  """
  @spec get_tip_page(viewer(), term(), keyword()) ::
          {:ok, tip_page()} | {:error, read_error() | :invalid_option}
  defdelegate get_tip_page(viewer, tip_id, opts \\ []), to: Read

  @doc """
  Reads the selected-review destination (`/reviews/:id`) for `viewer`: the
  review's own tip as context and that review, or its removal notice. See
  "Reading".
  """
  @spec get_review_page(viewer(), term()) ::
          {:ok, Projection.selected_review()} | {:error, read_error()}
  defdelegate get_review_page(viewer, review_id), to: Read

  @doc """
  Decides from current rows whether `viewer` may play the video `media_id`
  now, and returns its Stream uid. It writes nothing. First matching row:

  | Video | Result |
  |---|---|
  | Missing, not a video, cleanup-marked or not `:ready` | `:not_found` |
  | Attached; the tip or review is visible to everyone | ok, no token query |
  | Attached; parent hidden or deleted | ok if the readmitted viewer may read the parent (`Tips.Content.Visibility`) |
  | Staged | ok if the readmitted viewer is its author and its deadline has not passed |
  | Anything else, including a failed readmission | `:not_found` |

  A review's decision ignores its tip.
  """
  @spec get_media_access(viewer(), term()) ::
          {:ok, %{stream_uid: String.t()}} | {:error, :not_found}
  defdelegate get_media_access(viewer, media_id), to: Read

  @doc """
  Searches live tips for `query` within one time budget, falling back to
  keyword ranking when meaning-based ranking is unavailable. A failure is an
  error, never an empty page. See `Tips.Content.Search` ("Search requests").
  """
  @spec search_tips(Scope.t() | nil, String.t(), keyword()) ::
          {:ok, Search.page()} | {:error, Search.error()}
  defdelegate search_tips(scope, query, opts \\ []), to: Search

  @doc """
  Lists one page of live tips in Hot or New order, with exact setup filters.
  See "Browsing".
  """
  @spec list_tips(Scope.t() | nil, keyword()) ::
          {:ok, Browse.page()} | {:error, :invalid_option}
  defdelegate list_tips(scope, opts \\ []), to: Browse

  @doc """
  Reads one inbox page and, with `mark_read: true`, marks the unread
  notifications it captured. See "Inbox".
  """
  @spec get_inbox(viewer(), keyword()) ::
          {:ok, Notification.page()} | {:error, :unauthenticated | :invalid_option}
  defdelegate get_inbox(viewer, opts \\ []), to: Notification, as: :inbox

  @doc "Counts the scope's unread notifications, up to 100. See \"Inbox\"."
  @spec count_unread_notifications(Scope.t()) :: 0..100
  defdelegate count_unread_notifications(scope), to: Notification, as: :count_unread

  @doc """
  Returns the active curated tags, models and environments in display order:
  the values the discovery filters accept.
  """
  @spec list_filter_choices() :: Vocabulary.choices()
  defdelegate list_filter_choices, to: Vocabulary, as: :active_choices

  @doc """
  Deletes the author's own tip or review, irreversibly. See "Deletion and
  moderation".
  """
  @spec delete_content(Scope.t() | nil, kind(), pos_integer()) ::
          {:ok, lifecycle_receipt()} | {:error, delete_error()}
  defdelegate delete_content(scope, kind, id), to: Deletion, as: :delete

  @doc """
  Sets the scope's vote on a tip or review to `desired`. See "Voting".
  """
  @spec set_vote(Scope.t() | nil, kind(), pos_integer(), vote()) ::
          {:ok, vote_receipt()} | {:error, vote_error()}
  def set_vote(scope, kind, id, desired) when desired in [1, -1, nil],
    do: Voting.set(scope, kind, id, desired)

  @doc """
  Reports a suspected rule violation on a tip or review. See "Reporting".
  """
  @spec report_content(Scope.t() | nil, kind(), pos_integer(), map()) ::
          {:ok, report_receipt()} | {:error, report_error()}
  def report_content(scope, kind, id, attrs) when is_map(attrs),
    do: Moderation.report(scope, kind, id, attrs)

  @doc """
  Reads one moderation case for a moderator's session. See "Deletion and
  moderation".
  """
  @spec get_moderation_case(Accounts.SessionRef.t(), kind(), term()) ::
          {:ok, moderation_case()}
          | {:error, :unauthenticated | :forbidden | :not_found | :outcome_unknown}
  defdelegate get_moderation_case(session_ref, kind, id), to: Moderation, as: :get_case

  @doc """
  Hides a tip or review as the moderator reviewed it, resolving the reviewed
  reports. See "Deletion and moderation".
  """
  @spec hide_content(Scope.t() | nil, kind(), pos_integer(), pos_integer(), [pos_integer()]) ::
          {:ok, lifecycle_receipt()} | {:error, moderation_error()}
  def hide_content(scope, kind, id, expected_version, reviewed_report_ids),
    do: Moderation.moderate(:hide, scope, kind, id, expected_version, reviewed_report_ids)

  @doc """
  Restores a hidden tip or review as the moderator reviewed it. The reviewed
  reports stay open. See "Deletion and moderation".
  """
  @spec restore_content(Scope.t() | nil, kind(), pos_integer(), pos_integer(), [pos_integer()]) ::
          {:ok, lifecycle_receipt()} | {:error, moderation_error()}
  def restore_content(scope, kind, id, expected_version, reviewed_report_ids),
    do: Moderation.moderate(:restore, scope, kind, id, expected_version, reviewed_report_ids)
end
