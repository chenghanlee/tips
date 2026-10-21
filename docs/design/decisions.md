# Decisions

One line per decision: what and why. Newest date last. Link the evidence instead of
repeating it.

## 2026-10-21

- Agile, one story at a time, user demo before the next story. Why: learn through
  working software, not upfront packages.
- Front end: plain HTML, CSS and JS on Phoenix controllers and HEEx. Why: the first
  stories are pages and forms. LiveView was dropped for its server round trip on every
  event; it stays installed, unused. htmx, Alpine, React and Svelte were weighed and
  deferred.
- Growth rules: Alpine when JS passes about 100 lines or three widgets. htmx at the
  first partial-page update. A React or Svelte island only if the composer needs it.
  TypeScript when Alpine or an island arrives.
- Components: Basecoat, Vega style, from npm. daisyUI dropped. Why: shadcn look with no
  framework runtime.
- JS checks: Biome lints and formats `assets/js`. Why: every language in the repo has a
  linter and formatter.
- Browser tests: PhoenixTest with the Playwright driver, one screenshot per UI scenario
  into ignored `tmp/screenshots`. agent-browser stays for manual checks. Why: Phoenix
  standard, Ecto sandbox, Playwright already installed.
- Naming: schema `Post`, table `posts`, users see "tip". Why: `Tips.Content.Tip` reads
  badly.
- `uid` is a stored 12-character Nanoid. `slug` is stored, max 80 characters. Wrong
  slug redirects 301. Why: stable URLs, same title twice allowed.
- Validation in the changeset plus `null: false` and unique indexes. No CHECK
  constraints. Why: one writer today.
- Error text in the GOV.UK style. Why: the most used written standard.
- Body is plain text. Markdown is its own later story.
- PRD at `PRODUCT.md` (the Impeccable convention). Design facts in `docs/design`.
  Status on Project 15. Why: agents read files from their clone; PRs review changes.
- Reuse over invent: standards, guidelines, libraries and tools before our own.
- Skills: Vercel `web-design-guidelines` vendored in `agent/skills/`. Impeccable
  installed project-local by the user.
