# Tips components

These are the function components the reader and editor exemplars use. Each
exemplar region carries `data-component="<name>"` with a name from this file.
It lists only components that [frontend-design.md](../frontend-design.md)
requires.

Rules for every component:

- Function components in `TipsWeb`, called by module to avoid clashes with
  `CoreComponents` ([toolchain note](../../development/toolchain.md#library-selections)).
- No component holds page state. The page LiveView owns form, filter, search,
  upload, draft and vote state and passes it in; components render it and emit
  ordinary `phx-*` events or links.
- Native elements stay native: `<select>`, `<details>`, `<form>`, `<button>`,
  `<a>`, `<input type="file">`. Do not swap them for SaladUI's JS `select`,
  `collapsible` or `dialog`.
- Styling uses [tokens.md](tokens.md). Icons are Heroicons (outline, 24) by the
  names given below.

## Shared

`TipsWeb.UI` (`lib/tips_web/components/ui.ex`) is the interface. Each
function's `@doc` and `attr` declarations give its attrs, slots and use:
`site_header`, `button`, `field`, `model_field`, `filter_select`, `filter_bar`,
`search_form`, `setup_meta`, `tip_row`, `vote_control`, `page_nav`, `notice`,
`error_summary`, `disclosure`.

- `model_field`: a fresh review from a tip with a typed model opens on "Other
  model…" with the name filled in. Storage follows
  [data-model.md rule 6](../data-model.md#rules).
- `setup_meta`: reviewer setup uses `linkable={false}`.
- `notice`: Heroicon `exclamation-triangle` for errors, `arrow-path` for
  reconnecting.

## Discovery

`TipsWeb.Discovery` (`lib/tips_web/components/discovery.ex`) holds what browse
and search share: URL filter and page parsing, `filter_selects` and the
`tip_row` map with filter links that patch the current page.

## Tip page

`TipsWeb.Reader` (`lib/tips_web/components/reader.ex`) is the interface for
`tip_header`, `tip_context`, `contribution_control`, `markdown`,
`verbatim_block`, `removed_notice` and `review_card`.

## Not in the code

Parts of built components:

| Component | Part | Spec |
|---|---|---|
| `verbatim_block` | Copy | Attr `copy_label` ("Copy prompt", "Copy result"); a `<button>` beside the label. Status region `aria-live="polite"`: "Copied" or the manual-copy line |
| `tip_header`, `review_card` | Votes | `TipsWeb.UI.vote_control` with `variant="detail"` |
| `review_card` | Delete | Delete beside Edit, by `review.capabilities` |

Components:

| Name | Purpose | Attrs and slots | Wraps | Shown in |
|---|---|---|---|---|
| `attachment_view` | Published image, animated image or video | `media` (kind, description, `full_href`, `thumbnail_href`, `watch_href`, `is_animated`). Image: `<img alt>` plus a separate full-size link (new tab, Heroicon `arrow-top-right-on-square`). Animated: "Play animation" / "Hide animation" button, focus returns to it. Video: poster button (Heroicon `play`) that loads the watch iframe | `<figure>`, `<img>`, `<a>`, `<button>`, `<iframe>` | tip, reviews |
| `result_composer` | Result section: output textarea, helper, "Add images or video", limits, shared count, tray | `field`, `uploads`, `count`, `limit`; slot `item` | `<fieldset>`, `<textarea>`, `<input type="file">` behind a `<label>` styled as a button | `editor-review.html` |
| `attachment_item` | One tray entry | `item` (kind, filename, size, `state`: `:image`, `:missing`, `:uploading`, `:processing`, `:ready`, `:failed_transfer`, `:failed`), `position`, `total`, `description_field`, `expires_at`. Actions by state: Move earlier / Move later (disabled at ends), Remove, Reselect, Resume upload, Replace video. Buttons are `aria-describedby` the filename. Heroicons `exclamation-triangle` (needs action), `play` (uploading), `arrow-path` (processing), `check` (ready) | `<li>`, `<canvas>`, `<button>` | `editor-review.html` |
| `editor_bar` | Draft status line with the exit beside it, Publish with its wait explanation, Discard draft apart | `status` (draft vocabulary from frontend-design), `exit_label` ("Leave editor" or "Back to tip"), `exit_href`, `publish_disabled`, `wait_reason` | `<p role="status">`, `<a>`, `<button>` | `editor-review.html` |

## Not components

Page headings, the results heading and the review-list heading are plain
markup in each LiveView. The single-review "Show all reviews" link is an
ordinary `<a>`.
