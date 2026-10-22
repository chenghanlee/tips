# Checks

Per commit, run only the fast checks for the files you touched: the formatter, the
linter and the changed test module or test file. Run the full checks below once at the
PR head, before the push that opens the PR; on later heads, rerun the checks the new
commits affect. Do not rerun them on `main` or on intermediate commits. Run the checks
for each kind of file you changed:

| Changed files | Run |
|---|---|
| Application code, tests or config | [Test changes](../../README.md#test-changes), including `mix credo --strict` and `mix dialyzer`. The tester verifies the implementer's full-suite record instead of rerunning the full `mix test` suite ([substitution](../skills/review-software-correctness/SKILL.md#step-7-checks)) |
| `agent/teams` Python | [Harness checks](../teams/development.md#required-checks) |
| Go, including carried patches | [Pinned lint profile](../lsp/dexter/patches/README.md#required-go-static-analysis) |
| Markdown | `python3 scripts/check_docs.py` |

Fix the findings your change introduces; report the others.

Every `mix test` run follows [Test logs](test-logs.md). While GitHub Actions is paused,
record local checks as [GitHub CI pause](github-ci-pause.md) says.
