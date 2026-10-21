# Decisions

One bullet per decision: what and why. Newest date last. Facts live in the other
design docs; link them instead of repeating them.

## 2026-10-21

- Agile, one story at a time, user demo before the next story. Why: learn through
  working software, not upfront packages. Process rules are in
  [PRODUCT.md](../../PRODUCT.md#principles).
- Front end: plain HTML, CSS and JS on Phoenix controllers and HEEx. Why: the first
  stories are pages and forms. LiveView was dropped for its server round trip on every
  event; it stays installed, unused. The real look is decided in a design story after
  the user sees the first form.
- Deferred with growth rules: Alpine when JS passes about 100 lines or three widgets.
  htmx at the first partial-page update. A React or Svelte island only if the composer
  needs it. TypeScript when Alpine or an island arrives.
- Dropped: Inertia, Vite, server-side rendering, shadcn/ui, Wallaby, Playwright tests
  in TypeScript, agent-browser test scripts, the two React-only Vercel skills, a base-36
  uid, a computed slug, a glossary.
- Components: Basecoat, Vega style, from npm in `assets/`; import only the parts a story
  uses. daisyUI dropped. Why: the shadcn look with no framework runtime.
- JS checks: Biome lints and formats `assets/js`. Why: every language in the repo has a
  linter and formatter.
- Browser tests: PhoenixTest with the Playwright driver, one screenshot per UI scenario
  into ignored `tmp/screenshots`. agent-browser stays for manual checks. Why: the
  Phoenix standard, works with the Ecto sandbox, Playwright is already installed.
- Naming: schema `Post`, table `posts`; users see "tip" ([Posts](data-model.md#posts)).
  Why: `Tips.Content.Tip` reads badly.
- `uid` and `slug` are stored ([Posts](data-model.md#posts), [URLs](content.md#urls)).
  Why: stable URLs, and two posts may share a title.
- Validation in the changeset plus `null: false` and unique indexes, no CHECK
  constraints ([Rules](data-model.md#rules)). Why: one writer today.
- Error text in the GOV.UK style ([Validation and error text](content.md#validation-and-error-text)).
  Why: a public, user-tested standard for form error text.
- Body is plain text. Markdown is its own later story.
- PRD at `PRODUCT.md`, the Impeccable file name. Design facts in `docs/design`. Status
  on Project 15. Why: agents read files from their clone, and PRs review changes.
- Reuse over invent: standards, guidelines, libraries and tools before our own.
- Skills: Vercel `web-design-guidelines` vendored in `agent/skills/`. Impeccable is
  installed by the user ([setup](../../agent/teams/SETUP.md#one-time-setup)).
