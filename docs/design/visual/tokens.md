# Tips tokens

Light only: there is no dark theme. The exemplars in this directory use these
names as CSS custom properties.

Names and values are the SaladUI gray scheme that `mix salad.setup` writes
([toolchain note](../../development/toolchain.md#library-selections)), except
the three values marked **Tips**.

| Tokens | Defined in |
|---|---|
| Colour tokens and `--radius` | `:root` in `assets/css/app.css` |
| `--font-sans`, `--font-mono`, `--container-reading`, `--container-editor` | `@theme` in `assets/css/app.css` |
| `--text-*`, `--leading`, `--space-*`, `--control-sm`, `--control-md` | Not in `assets/css/app.css`; only in the exemplars. Code uses the class in the Tailwind column |

## Colour

Values are in `assets/css/app.css`. Contrast ratios are against
`--background` unless stated.

| Token | Use and contrast |
|---|---|
| `--background` | Page |
| `--foreground` | Body text, 20:1 |
| `--card` / `--card-foreground` | Bordered regions |
| `--primary` | Primary buttons, selected vote |
| `--primary-foreground` | Text on primary, 17:1 |
| `--secondary` / `--secondary-foreground` | Secondary buttons |
| `--muted` | Prompt and Result block background |
| `--muted-foreground` | Row metadata, helper text. 4.8:1 on background, 4.4:1 on `--muted`: use it only on `--background` or `--card` |
| `--accent` / `--accent-foreground` | Hover background; same values as secondary |
| `--destructive` | **Tips** `oklch(0.577 0.245 27.325)`. Error text, error borders, Discard/Remove. 4.8:1. SaladUI's `oklch(0.637 0.208 25.326)` is 3.8:1 and fails as text |
| `--destructive-foreground` | Text on destructive, 4.55:1 |
| `--border` | A border colour, as in SaladUI. Dividers and region outlines (decorative) |
| `--input` | **Tips** `oklch(0.64 0.022 261.325)`. Borders of inputs, textareas, selects and outline buttons. 3.4:1 on background, 3.1:1 on `--muted`, meeting the 3:1 non-text contrast rule. SaladUI's value equals `--border` (1.2:1) |
| `--ring` | Focus outline |

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

Side padding is `--space-4` (16 px) at every width. Adjacent buttons keep
`--space-2` (8 px) between them.

## Focus

Every focusable element shows a 2 px `--ring` outline, offset 2 px, on
`:focus-visible`. `app.css` has one rule:

```css
:focus-visible { outline: 2px solid var(--ring); outline-offset: 2px; }
```

The rule is unlayered, so it beats the `focus-visible:outline-hidden` utility
on SaladUI's button, input and textarea. The focusable error summary
(`tabindex="-1"`) gets the same outline when script moves focus to it.

## Prompt and Result blocks

`--font-mono`, `--text-sm`, `--muted` background, `--radius`, padding
`--space-3`. Use `white-space: pre-wrap; overflow-wrap: anywhere;` so text
soft-wraps and never scrolls sideways at 320 px. Copied bytes are the stored
text, not the rendered layout.
