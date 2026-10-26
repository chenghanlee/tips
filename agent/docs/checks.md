# Checks

Per commit, run only the fast checks for the files you touched: the formatter, the
linter and the changed test module or test file. Run the full checks below once at the
PR head, before the push that opens the PR; on later heads, rerun the checks the new
commits affect. Do not rerun them on `main` or on intermediate commits. Run the checks
for each kind of file you changed:

| Changed files | Run |
|---|---|
| Application code, tests or config | [Test changes](../../README.md#test-changes), including `mix credo --strict`; `mix dialyzer` only as [Dialyzer](#dialyzer) says |
| `agent/teams`, other than Markdown | [Harness checks](../teams/development.md#required-checks). The tester runs the applicable checks itself, including the real-daemon tests for non-Markdown `agent/teams` changes and ShellCheck; the required-checks table names the opt-ins, and the suite summary names an opt-in it skipped |
| Go, including carried patches | [Pinned lint profile](../lsp/dexter/patches/README.md#required-go-static-analysis) |
| Markdown | `python3 scripts/check_docs.py` |

Fix the findings your change introduces; report the others. Every `mix test` run
follows [Test logs](test-logs.md).

## GitHub CI pause

While GitHub Actions is paused (user's decision of 2026-10-18), local checks and
independent review replace hosted execution and passing CI status. Nothing else changes.

1. Run the applicable checks locally before handoff. Missing tools, denied execution
   and skipped required checks are blockers, not passes; report them without bypassing
   a denial.
2. Record each check in the PR body so the record alone supports the merge decision:
   the underlying command, tested head, environment, exit, result with excluded or
   skipped counts, and the per-run results or failure excerpts a classification depends
   on. Working logs stay in the clone until cleanup; the PR may name one but must not
   depend on it. Independent review is still required.
3. After a change, rerun the affected checks. A reviewer carries earlier evidence
   forward only after inspecting the intervening diff and recording why it still
   applies.
4. Keep merge authorization, a current-head review, resolved threads and mergeability
   ([merge](../teams/README.md#merge)). Do not wait for paused workflows or call their
   billing failures code failures. Report a conflicting GitHub required-status rule to
   the user; do not bypass it.

Resuming CI is a [setup step](../teams/SETUP.md#resuming-ci).

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
record the [policy](#github-ci-pause) requires. The record must cover that head
completely; missing, contradictory or inapplicable evidence means the required check is
missing. The tester still runs the other checks for the changed file kinds in its own
database and port, runs the suite when its investigation needs it, and runs harness
Python checks itself. User's decision of 2026-10-20
([#515](https://github.com/chenghanlee/tips/issues/515)). Lost: a second unconditional
application-suite run in another database, port and runtime.
