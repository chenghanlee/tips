# Tips components

These are the function components the reader and editor exemplars use. Each
exemplar region carries `data-component="<name>"` with a name from this list.
The list holds only components that
[frontend-design.md](../frontend-design.md) already requires; it is not a
catalogue.

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

**Owner** is the issue that builds the component. The shared UI owner
([P16.02, #42](https://github.com/chenghanlee/tips/issues/42)) builds the shared
components; consuming tasks request changes from it instead of editing them.
Page-specific components belong to the listed feature task.

## Shared: built by #42

Implemented in `lib/tips_web/components/ui.ex` (`TipsWeb.UI`).

| Name | Purpose | Attrs and slots | Wraps | Shown in |
|---|---|---|---|---|
| `site_header` | Top bar: Tips home link and account link | `current_scope`; `editor` (boolean: render exits as ordinary `<a href>` so the leave warning covers them); `return_to` (optional allowed local destination, default nil: Log in and Register carry it as their `return_to` query; public tip and review pages pass their permalink through `Layouts.app`) | `<header>`, `<a>` | all three files, top |
| `button` | SaladUI `button` with Tips sizes | `variant` (`default` primary, `outline`, `secondary`, `ghost`, `destructive`, `link`), `size` (`lg` = 40 px for primary actions, `sm` = 32 px otherwise), `type`, `disabled`, `rest`; `inner_block`. Links styled as buttons use SaladUI's `button_variant/1` class on `<.link>` | `<button>` | everywhere |
| `field` | Label, control, helper and error for one form field | `field` (`Phoenix.HTML.FormField`), `label`, `type` (`text`, `textarea`, `select`), `options` (select), `helper`, `rows`. Error text shows after the first submission (gate with `used_input?/1`); sets `aria-invalid` and `aria-describedby` for helper and error. No `maxlength`, no `required` | SaladUI `form_item`, `form_label`, `input`/`textarea`, native `<select>`, `form_description`, `form_message` | `editor-review.html` |
| `model_field` | Optional model in tip and review forms: a curated model or a typed name. Used by both forms | `select_field` (`model_id`), `text_field` (`model_other`), `options` ("Not specified", the curated models, then "Other model…" with value `other`). The labelled "Model name" input, helper "Up to 80 characters. Shown as plain text, not as a filter.", is present only while the select is `other`; the page renders it on its existing `phx-change`, with no hook. No `maxlength`. Publishing stores exactly one of `model_id` / `model_other`. A fresh review from a free-text tip model opens on Other model… with the name filled in | `<select>`, `<input type="text">` | `editor-review.html` |
| `filter_select` | One labelled native select that updates the list on change | `id`, `name`, `label`, `options` (All first), `value` | `<select>` | browse toolbar, search, tip-page review filters |
| `filter_bar` | Filter group: the "Changing a selection updates the list" note, its selects, and Clear filters when any filter is active | `id`, `active` (boolean), `clear_href` (patch URL: filters to All, query and sort kept, page 1), `note`; `inner_block` (the `filter_select`s) | `<form phx-change>` | browse, search, review filters |
| `search_form` | Task-framed search field with Search button and the blank-search message | `value` (last submitted query), `error` (blank message or nil), `action`. Blank submit: message shown, field focused, no `required`. Heroicon `magnifying-glass` | `<form role="search">`, `<input type="search">`, `<button>` | browse, search |
| `setup_meta` | Technique, model and environment line | `technique`, `model` (`{:curated, label, href}`, `{:free_text, label}` or nil), `environment`, `linkable` (false for reviewer setup: all plain text). Free-text model is always plain text | `<span>`, `<a>` | feed rows, tip header, reviews |
| `tip_row` | Compact text-only feed and search row | `tip` (title, `href`, net score, review count, age, author handle and `href`, setup), `vote` (assigns for `vote_control`); slot `excerpt` (attrs `source`: Review, Prompt, Result or Reviewer setup, `href`; ~200 escaped chars). Title, tag, model and author are separate links, never nested | `<li>`, `<a>` | browse feed, search results |
| `vote_control` | Helpful / Not helpful | `variant` (`compact` in rows, `detail` with "Helpful N" / "Not helpful N"), `selected` (`:helpful`, `:not_helpful`, nil), `pending` (boolean), `counts`, `target`. Buttons carry `aria-pressed`; pending sets `aria-disabled` on both (not `disabled`, so focus stays on the clicked button), ignores clicks and shows a polite status. Behaviour wired by [#110](https://github.com/chenghanlee/tips/issues/110) | `<button>` ×2 | feed rows, tip, reviews |
| `page_nav` | Previous, current page, Next | `page`, `prev_href`, `next_href` (nil hides), `first_href`, `out_of_range` (boolean: shows Previous and First page) | `<nav aria-label>`, `<a>` | browse, search, reviews |
| `notice` | One-line status, empty state, placeholder or error with actions | `tone` (`neutral`, `error`), `role` (`status`, `alert` or none), `id`; `inner_block`; slot `actions`. Heroicons `exclamation-triangle` (error), `arrow-path` (reconnecting). Not SaladUI `alert`, which hard-codes `role="alert"` | `<div>` | all files: loading, retrieval error, empty lines, placeholders, updated-tip note, connection, conflict, stale-save, handoff |
| `error_summary` | Submit-time error list that takes focus and links to fields | `errors` (`[{field_id, message}]`). `tabindex="-1"`, heading, list of `<a href="#field_id">` | `<div role="alert">` | `editor-review.html` |
| `disclosure` | Native disclosure that keeps its open state across patches | `id`, `open`, `summary`; `inner_block`. Applies `JS.ignore_attributes(["open"])` per the toolchain note. Never nested | `<details>`, `<summary>` | reviews, composer |

## Page-specific: built by the feature task

| Name | Owner | Purpose | Attrs and slots | Wraps | Shown in |
|---|---|---|---|---|---|
| `tip_header` | [#77](https://github.com/chenghanlee/tips/issues/77) | Tip title, author, dates, `setup_meta`, `contribution_control`, tip `vote_control` | `tip`, `own_review`, `capability` | `<header>`, `<h1>` | `reader-tip.html` |
| `contribution_control` | [#77](https://github.com/chenghanlee/tips/issues/77) | One control near the header, by viewer state | `state` (`:own_review`, `:write`, `:sign_in`, `:not_accepting`, `:none`), `href`. `:not_accepting` is a disabled button with visible explanation; `:none` renders nothing | `<a>` or `<button disabled>` | `reader-tip.html` |
| `verbatim_block` | [#77](https://github.com/chenghanlee/tips/issues/77); Copy by [#99](https://github.com/chenghanlee/tips/issues/99) | Prompt or Result text with its Copy action and status | `label` (Prompt, Result), `text`, `copy_label` ("Copy prompt", "Copy result"), `id`. Status region `aria-live="polite"`: "Copied" or the manual-copy line | `<figure>`, `<pre>`, `<button>` | tip, reviews |
| `attachment_view` | [#99](https://github.com/chenghanlee/tips/issues/99) | Published image, animated image or video | `media` (kind, description, `full_href`, `thumbnail_href`, `watch_href`, `is_animated`). Image: `<img alt>` plus a separate full-size link (new tab, Heroicon `arrow-top-right-on-square`). Animated: "Play animation" / "Hide animation" button, focus returns to it. Video: poster button (Heroicon `play`) that loads the watch iframe | `<figure>`, `<img>`, `<a>`, `<button>`, `<iframe>` | tip, reviews |
| `review_card` | [#98](https://github.com/chenghanlee/tips/issues/98) (first render in #77) | One review: author, dates, reviewer `setup_meta` (`linkable: false`), Markdown body, evidence `disclosure`, `vote_control` detail, own actions | `review`, `open` (single-review view), `capabilities` (Edit, Delete) | `<article>` | `reader-tip.html` |
| `result_composer` | [#88](https://github.com/chenghanlee/tips/issues/88) | Result section: output textarea, helper, "Add images or video", limits, shared count, tray | `field`, `uploads`, `count`, `limit`; slot `item` | `<fieldset>`, `<textarea>`, `<input type="file">` behind a `<label>` styled as a button | `editor-review.html` |
| `attachment_item` | [#88](https://github.com/chenghanlee/tips/issues/88); canvas [#89](https://github.com/chenghanlee/tips/issues/89); missing slot and video recovery [#90](https://github.com/chenghanlee/tips/issues/90) | One tray entry | `item` (kind, filename, size, `state`: `:image`, `:missing`, `:uploading`, `:processing`, `:ready`, `:failed_transfer`, `:failed`), `position`, `total`, `description_field`, `expires_at`. Actions by state: Move earlier / Move later (disabled at ends), Remove, Reselect, Resume upload, Replace video. Buttons are `aria-describedby` the filename. Heroicons `exclamation-triangle` (needs action), `play` (uploading), `arrow-path` (processing), `check` (ready) | `<li>`, `<canvas>`, `<button>` | `editor-review.html` |
| `editor_bar` | [#78](https://github.com/chenghanlee/tips/issues/78); exits and discard [#92](https://github.com/chenghanlee/tips/issues/92) | Draft status line with the exit beside it, Publish with its wait explanation, Discard draft apart | `status` (draft vocabulary from frontend-design), `exit_label` ("Leave editor" or "Back to tip"), `exit_href`, `publish_disabled`, `wait_reason` | `<p role="status">`, `<a>`, `<button>` | `editor-review.html` |

## Not components

Page headings, the results heading and the review-list heading are plain
markup in each LiveView. The single-review "Show all reviews" link is an
ordinary `<a>`.
