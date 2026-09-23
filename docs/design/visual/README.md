# Visual baseline

This directory is the Tips visual baseline for the reader and editor pages. It
settles the look, the tokens and the shared component interfaces so
[P16.02](https://github.com/chenghanlee/tips/issues/42) can implement them
without further design decisions. It follows
[frontend-design.md](../frontend-design.md) and the SaladUI result in
[toolchain.md](../../development/toolchain.md#library-selections).

## Files

| File | What it is |
|---|---|
| [tokens.md](tokens.md) | Colour, type, spacing, radius, focus and width tokens; the `--border` resolution and daisyUI removal |
| [components.md](components.md) | Shared component interfaces and page-specific components, with owners |
| `reader-browse.html` | Browse and search page, with loading, error, blank-search, empty and out-of-range states |
| `reader-tip.html` | Tip page with media, reviews, placeholders and the single-review view |
| `editor-review.html` | Review composer with attachments, errors, draft status and recovery states |

The HTML files are static and self-contained: inline CSS, no web fonts, no
external requests. The only script is a few optional lines in
`reader-tip.html` for Copy and Play animation; the page reads the same without
it. Each file shows the main page first, then labelled "State: …" boxes below
a dashed "States" rule. The dashed boxes and monospace labels are annotations,
not product UI.

Every region carries `data-component="<name>"`, a name from
[components.md](components.md). CSS custom properties use the names in
[tokens.md](tokens.md).

## Review them

Open a file in a browser from a checkout (`file://`), or download it from its
GitHub raw link.

1. **320 px.** In Chrome DevTools, turn on device emulation (Cmd+Shift+M) and
   set the width to 320. Check that nothing scrolls sideways:
   `document.scrollingElement.scrollWidth` must be `320` in the console.
2. **Desktop.** Look at 1280 px. Reading pages stop at 48 rem, the editor at
   40 rem.
3. **Keyboard.** Click an empty area at the top of the page, then press Tab
   through the whole page. Every stop must show a 2 px dark outline with a gap.
   Order follows the page top to bottom; state boxes follow the main page.

Screenshots at 1280 px from the command line (Chrome keeps running after
writing the file, so bound it with `timeout`; exit 124 is expected):

```sh
timeout 20 "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars --user-data-dir="$(mktemp -d)" \
  --window-size=1280,4000 --screenshot=reader-browse-1280.png \
  "file://$PWD/docs/design/visual/reader-browse.html"
```

Do not use `--window-size=320,4000` for the narrow shot. Headless Chrome 153
enforces a 500 px minimum window, so the page lays out at 500 px and the
screenshot crops it. Use DevTools emulation as above, or the DevTools Protocol
`Emulation.setDeviceMetricsOverride` with `width: 320`.

## Settled here

- Token values, including the Tips changes to SaladUI defaults (`--radius`,
  `--destructive`, `--input`) and the 2 px focus outline.
- Removing daisyUI when SaladUI is installed, which resolves the `--border`
  clash.
- Layout: widths, spacing, control heights, the compact text-only feed row,
  and how each state looks.
- Which components exist, what they wrap, their attrs and slots, and who builds
  them.

## Settled in P16.02 and the feature tasks

- HEEx code, module paths, exact function heads and tests.
- Wiring: LiveView events, hooks, uploads, draft storage and vote behaviour.
  The exemplars show state; they do not implement it.
- Real media, real content and the rest of the page areas; P16.03
  ([#117](https://github.com/chenghanlee/tips/issues/117)) reviews those.

## Copy

Where [frontend-design.md](../frontend-design.md) fixes the wording, the
exemplars use it exactly. It does not fix these lines, which feature owners may
reword without a design change: the search label and helper, the Model and
Environment filter note, "Saving…", "Net +N", "Loading results…", the
retrieval-error line, "No tips on page N.", the Copy failure line, "Play video",
"Open full-size image", the Review and image-description helpers, video state
explanations, the connection, stale-save, conflict and handoff notices, and the
error-summary heading.
