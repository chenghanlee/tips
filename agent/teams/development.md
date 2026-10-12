# Changing agent/teams scripts

## Required checks

For Python changes in `agent/teams`, the required CI job `checks` runs:

```sh
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

Run these commands in your worktree before pushing if Ruff and Pyright are on
`PATH`. Otherwise, use CI.

Run these additional tests for the listed changes:

| Change | Required tests | Execution and evidence |
|---|---|---|
| Provisioning or client stopping | Real-daemon tests (`-k real_daemons`), with `TIPS_TEST_REAL_DEXTER` and `DEXTER_ELIXIR_LIB_ROOT` set. See the [LSP guide](../lsp/README.md). | CI runs these in the `dexter` job against the newly built binary. |
| Codex launch arguments or generated Codex configuration | Installed-Codex tests, with `TIPS_TEST_REAL_CODEX=1`. | Run locally and record the result on the PR. CI has no Codex client. |

## Dependencies and test isolation

- Scripts use only the Python standard library.
- Tests use disposable Git repositories, fake Herdr and child processes they own.
  Never use live pairs in tests.
- Tests need permission to run `ps` and send signals to their own child processes.

## Lint exceptions

The reviewed `# noqa: S603` exceptions apply only to `team.py:execute`,
`capture.py:run_into`, `StopAgentTest.client` and the two `CaptureTest` child
launches. These calls use variable argument lists, no shell, a resolved executable,
and fixed, caller-supplied or test-owned arguments. `capture.py` imports nothing from
`team.py`, so replacing the orchestrator does not affect it.

When changing either call, review the executable selection and arguments for
safety. Lint does not verify their safety. Do not suppress other warnings.

Lint and type-check settings are in [pyproject.toml](pyproject.toml).

## Repeated failures

If a pair fails the same way twice, fix the tool or its error message before
adding a workflow rule.
