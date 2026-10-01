defmodule TipsWeb.EditorContract do
  @moduledoc """
  The browser draft, recovery and handoff contract shared by the tip and review
  editors and their `EditorDraft` hook.

  This module only declares types. The editor page and hook (#78), browser
  storage (#75) and the Content comparator (#72) implement them. Server inputs
  and results stay `Tips.Content` types; `assets/js/editor_contract.js`
  declares the same shapes as JSON. Examples live in
  `TipsWeb.EditorContractFixtures`. See "Saving and recovery" and
  "Publication-to-edit handoff" in `docs/design/frontend-design.md`.

  ## Identities

  Four values guard different effects and never stand in for one another:

    * `t:storage_identity/0` says where a browser record lives: one new-tip
      slot per account, one new-review slot per account and parent tip, and
      one edit slot per account and published item. It never authorizes.
    * `t:draft_pair/0` guards every browser write, discard and clear. A new
      draft's id is its submission key; an edit draft has its own local UUID.
      The same revision under another draft id is another draft.
    * `submission_key` identifies one intended publication to Content.
    * `expected_version` is the server `edit_version` the edit was based on.

  ## Records

  A `t:draft_record/0` is `:new` or `:edit`; being recovered is how an editor was
  entered, not a mode. `target` is the logical form: what a save would do. It
  equals the storage slot except after a handoff. An edit record holds the
  complete immutable base and expected version from `get_edit_form/3`;
  autosave and restore never change them. A missing or incomplete base never
  enables safe conflict recovery.

  `intent` holds every editable field exactly as typed, including `nil`,
  empty and whitespace-only values, and the ordered media selection. Content
  owns normalization (#72). `uploads: nil` means the selection is unknown,
  never empty. A submission maps each `t:media/0` to its `t:Tips.Content.attachment/0`:
  `{:missing_image, slot, image}` becomes `{:missing_image, slot}`, so
  browser metadata never proves saved bytes. Records hold no bytes, temporary
  server paths, provider URLs or tokens.

  ## Handoff

  Continue as edit keeps record K in its new-form slot with its draft id and
  submission key, and writes the exact item, complete base and expected
  version under K's current draft pair; the write advances K's revision. An
  ordinary edit record E stays unchanged. An uncertain edit reconciles as an
  edit, never through the publication key.

  ## Clearing

  After a submission the page sends a `t:clear_request/0` only for the exact
  submitted draft: a `:created` or `:existing_equivalent` publication receipt
  with the same kind, parent and submission key, or an `:updated` or `:noop`
  edit receipt of the same item. Anything else preserves the proposal. The
  request is an instruction: the hook clears only a stored record with the
  same storage and draft pair, and newer work stays.

  ## Page and hook

  The form and hook element id is `editor-<account_id>-<tip|review>` and stays
  stable through the same-kind handoff. The element carries
  `data-editor-identity` (JSON `t:identity/0`) and `data-editor-record` (the
  rendered JSON record), mirrored in the hidden inputs `editor[identity]` and
  `editor[record]`. The form sets `phx-auto-recover="editor:recover"`. Hidden
  identity is checked against the freshly mounted identity and never trusted
  for authorization; another account or target needs a fresh hook or
  equivalent guards.

  | Event | Direction | Payload |
  |---|---|---|
  | `editor:restore` | hook to LiveView | `t:restore_request/0`, replied with `t:restore_reply/0` |
  | `editor:recover` | form to LiveView | hidden identity and record with the current form fields |
  | `editor:handoff` | LiveView to hook | `t:handoff/0` |
  | `editor:clear` | LiveView to hook | `t:clear_request/0` |

  The hook sends `editor:restore` only on a fresh mount, never on reconnect.
  `:restored` settles recovery, not publication; `:preserved` keeps typed
  input; `:rejected` means the recovered identity is not this form's. With no
  record or a storage error the author composes without a restore reply.
  Reconnect uses `editor:recover` and reads no storage.
  """

  alias Tips.Content

  @typedoc "A logical form or storage slot: new tip, new review of a tip, or edit of an item."
  @type target ::
          :new_tip
          | {:new_review, tip_id :: pos_integer()}
          | {:edit, Content.kind(), id :: pos_integer()}

  @typedoc "Where a browser record is stored. Never authorization."
  @type storage_identity :: %{account_id: pos_integer(), slot: target()}

  @typedoc "The current account and logical form of a mounted editor."
  @type identity :: %{account_id: pos_integer(), target: target()}

  @typedoc "The browser draft guard: record id and revision."
  @type draft_pair :: %{draft_id: Ecto.UUID.t(), revision: non_neg_integer()}

  @typedoc "Whether a record publishes new content or edits a published item."
  @type mode :: :new | :edit

  @typedoc "What the browser keeps of an image whose file must be reselected. Never bytes."
  @type image_descriptor :: %{
          filename: String.t(),
          type: String.t(),
          size: non_neg_integer(),
          description: Content.description()
        }

  @typedoc "One slot of the ordered browser selection."
  @type media ::
          {:retained, Content.media_id(), Content.description()}
          | {:staged_video, Content.media_id()}
          | {:missing_image, Content.slot(), image_descriptor()}

  @typedoc "Every editable field as typed, and the ordered selection or `nil` when unknown."
  @type intent :: %{attrs: Content.attrs(), uploads: [media()] | nil}

  @typedoc "One browser draft."
  @type draft_record :: %{
          storage: storage_identity(),
          draft: draft_pair(),
          mode: mode(),
          target: target(),
          submission_key: Content.submission_key() | nil,
          intent: intent(),
          base: Content.intent() | nil,
          expected_version: pos_integer() | nil
        }

  @typedoc "`editor:restore`: the hook's current identity and the record it read."
  @type restore_request :: %{identity: identity(), record: draft_record()}

  @typedoc "How the page settled a restore."
  @type restore_status :: :restored | :preserved | :rejected

  @typedoc "The reply to `editor:restore`, naming the record it settles."
  @type restore_reply :: %{
          status: restore_status(),
          storage: storage_identity(),
          draft: draft_pair()
        }

  @typedoc "`editor:handoff`: K's storage and current pair, and its edit-mode record."
  @type handoff :: %{storage: storage_identity(), expected: draft_pair(), record: draft_record()}

  @typedoc "The draft a submission was made from."
  @type submitted_draft :: %{storage: storage_identity(), draft: draft_pair(), target: target()}

  @typedoc "`editor:clear`: the submitted draft and the receipt that acknowledged it."
  @type clear_request :: %{
          submitted: submitted_draft(),
          receipt: Content.publication_receipt() | Content.edit_receipt()
        }
end
