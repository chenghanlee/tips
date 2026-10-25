# Checks

Per commit, run only the fast checks for the files you touched: the formatter, the
linter and the changed test module or test file. Run the full checks below once at the
PR head, before the push that opens the PR; on later heads, rerun the checks the new
commits affect. Do not rerun them on `main` or on intermediate commits. Run the checks
for each kind of file you changed:

| Changed files | Run |
|---|---|
| Application code, tests or config | [Test changes](../../README.md#test-changes), including `mix credo --strict`; `mix dialyzer` only as [Dialyzer](#dialyzer) says |
| `agent/teams` Python | [Harness checks](../teams/development.md#required-checks) |
| Go, including carried patches | [Pinned lint profile](../lsp/dexter/patches/README.md#required-go-static-analysis) |
| Markdown | `python3 scripts/check_docs.py` |

Fix the findings your change introduces; report the others.

Every `mix test` run follows [Test logs](test-logs.md). While GitHub Actions is paused,
record local checks as [GitHub CI pause](github-ci-pause.md) says.

## Dialyzer

`mix dialyzer` is not a per-PR check. Run it on `main` after each day's merges (the
dispatcher, while CI is paused; a nightly job on `main` once CI resumes), before a
release or demo, and on a PR only when its diff touches `@spec`, `@type`, `@callback`,
`@behaviour` or `mix.lock`. A finding on `main` is fixed in a small follow-up PR. User's
decision of 2026-10-26. Lost: a spec mismatch can sit on `main` until the next run.
Credo stays per PR: it costs seconds.

## Application suite substitution

The tester does not rerun the full application `mix test` suite. It verifies the
implementer's record for the reviewed head instead: a CI run, or during the CI pause the
record [GitHub CI pause](github-ci-pause.md) requires. The record must cover that head
completely; missing, contradictory or inapplicable evidence means the required check is
missing. The tester still runs the other checks for the changed file kinds in its own
database and port, runs the suite when its investigation needs it, and runs harness
Python checks itself. User's decision of 2026-10-20
([#515](https://github.com/chenghanlee/tips/issues/515)). Lost: a second unconditional
application-suite run in another database, port and runtime.
