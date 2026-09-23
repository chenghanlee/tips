# Tips tokens

These are the values [P16.02](https://github.com/chenghanlee/tips/issues/42)
puts in `assets/css/app.css`. The exemplars in this directory use the same
names as CSS custom properties. Light only: there is no dark theme.

Start from what `mix salad.setup` writes (verified in
[#41](https://github.com/chenghanlee/tips/issues/41), recorded in
[toolchain.md](../../development/toolchain.md#library-selections)). Keep the
SaladUI names. Change only the three values marked **Tips**, and add the
[focus rule](#focus).

## Colour

| Token | Value | Use |
|---|---|---|
| `--background` | `oklch(1 0 0)` | Page |
| `--foreground` | `oklch(0.129 0.027 261.671)` | Body text, 20:1 on background |
| `--card` / `--card-foreground` | `oklch(1 0 0)` / `oklch(0.129 0.027 261.671)` | Bordered regions |
| `--primary` | `oklch(0.21 0.032 264.652)` | Primary buttons, selected vote |
| `--primary-foreground` | `oklch(0.984 0.002 247.839)` | Text on primary, 17:1 |
| `--secondary` / `--secondary-foreground` | `oklch(0.967 0.003 264.542)` / `oklch(0.21 0.032 264.652)` | Secondary buttons |
| `--muted` | `oklch(0.967 0.003 264.542)` | Prompt and Result block background |
| `--muted-foreground` | `oklch(0.551 0.023 264.365)` | Row metadata, helper text. 4.8:1 on background, 4.4:1 on `--muted`: use it only on `--background` or `--card` |
| `--accent` / `--accent-foreground` | same as secondary | Hover background |
| `--destructive` | **Tips** `oklch(0.577 0.245 27.325)` | Error text, error borders, Discard/Remove. SaladUI's `oklch(0.637 0.208 25.326)` is 3.8:1 and fails as text; this is 4.8:1 on background |
| `--destructive-foreground` | `oklch(0.984 0.002 247.839)` | Text on destructive, 4.55:1 |
| `--border` | `oklch(0.928 0.006 264.531)` | Dividers and region outlines (decorative) |
| `--input` | **Tips** `oklch(0.64 0.022 261.325)` | Borders of inputs, textareas, selects and outline buttons. 3.4:1 on background, 3.1:1 on `--muted`, meeting the 3:1 non-text contrast rule; SaladUI's value equals `--border` (1.2:1) |
| `--ring` | `oklch(0.129 0.027 261.671)` | Focus outline |

Errors are destructive text or a destructive left border on `--background`.
Do not put destructive text on a red tint; it drops below 4.5:1.

## Type

| Token | Value | Tailwind |
|---|---|---|
| `--font-sans` | `ui-sans-serif, system-ui, sans-serif` | `font-sans` (default) |
| `--font-mono` | `ui-monospace, monospace` | `font-mono`; Prompt and Result blocks |
| `--text-sm` | `0.875rem` (14 px) | `text-sm`; row metadata, helper text, labels of small controls |
| `--text-base` | `1rem` (16 px) | `text-base`; body, feed row titles, inputs |
| `--text-lg` | `1.125rem` | `text-lg`; section headings |
| `--text-2xl` | `1.5rem` | `text-2xl`; page heading (tip title) |
| `--leading` | `1.5` | `leading-normal` on body |

No web fonts. Headings use weight 600; everything else 400. Inputs, textareas
and selects use `--text-base` so iOS does not zoom on focus; SaladUI's input
and textarea default to `text-sm`.

## Spacing, size and shape

| Token | Value | Tailwind |
|---|---|---|
| `--space-1` … `--space-8` | 4, 8, 12, 16, 24, 32 px (steps 1, 2, 3, 4, 6, 8) | `--spacing: 0.25rem` steps: `p-1` … `p-8` |
| `--radius` | **Tips** `0.375rem` | SaladUI derives `rounded-sm/md/lg/xl` from it; its default is `1rem` |
| `--control-sm` | `32px` | `h-8`; row, tray, Copy and secondary buttons. SaladUI button `size="sm"` plus `text-sm` (its default is `text-xs`) |
| `--control-md` | `40px` | `h-10`; primary actions, inputs and selects. SaladUI button `size="lg"` |
| `--container-reading` | `48rem` | `max-w-reading`; browse, search and tip pages |
| `--container-editor` | `40rem` | `max-w-editor`; composers |

Add the two containers to `@theme` in `app.css`:
`--container-reading: 48rem; --container-editor: 40rem;`.

Side padding is `--space-4` (16 px) at every width. Adjacent buttons keep
`--space-2` (8 px) between them.

## Focus

Every focusable element shows a 2 px `--ring` outline, offset 2 px, on
`:focus-visible`. Put one base rule in `app.css`:

```css
:focus-visible { outline: 2px solid var(--ring); outline-offset: 2px; }
```

SaladUI's button, input and textarea add `focus-visible:outline-hidden` with a
1 px or 50 % `ring`; override it through the component's `class` attr so the
base outline shows. The focusable error summary (`tabindex="-1"`) gets the same
outline when script moves focus to it.

## Prompt and Result blocks

`--font-mono`, `--text-sm`, `--muted` background, `--radius`, padding
`--space-3`. Use `white-space: pre-wrap; overflow-wrap: anywhere;` so text
soft-wraps and never scrolls sideways at 320 px. Copied bytes are the stored
text, not the rendered layout.

## `--border` resolution

daisyUI and SaladUI both define `--border`: daisyUI as a border width, SaladUI
as a border colour. Tips keeps SaladUI's meaning. P16.02 removes daisyUI in the
same change that installs SaladUI, so the two never coexist:

- Delete both `daisyui-theme` blocks and the `daisyui` plugin from `app.css`.
- Delete SaladUI's `.dark` block and the `@custom-variant dark` line.
- Delete the generated theme toggle (`Layouts.theme_toggle/1`), the
  `phx:set-theme` script in `root.html.heex`, and `data-theme` handling.
- Replace the remaining daisyUI classes (`btn`, `alert`, `divider`, `menu`,
  `badge`, `base-*`) in `core_components.ex`, `layouts.ex`, the generated
  `user_live` pages and `page_html/home.html.heex` with SaladUI components or
  plain Tailwind utilities over these tokens.
- Write the base border rule as `border-color: var(--border);`. The installer's
  `hsl(var(--border))` is invalid with oklch values, which leaves borders at
  `currentColor`.

This follows the [toolchain note](../../development/toolchain.md#library-selections):
remove daisyUI when SaladUI replaces the generated components. Keep Heroicons.
