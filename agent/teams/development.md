# Changing agent/teams scripts

For `agent/teams` Python changes, the required `checks` job runs these commands:

```sh
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

Run these before pushing, in your worktree, if Ruff and Pyright are on `PATH`; otherwise use CI. Scripts use only standard-library dependencies. Tests use disposable Git repositories, fake Herdr and owned child processes, never live pairs. Tests need permission to run `ps` and signal their own children.

Provisioning and client-stop changes also require the real-daemon tests (`-k real_daemons`) with `TIPS_TEST_REAL_DEXTER` and `DEXTER_ELIXIR_LIB_ROOT` set (see the [LSP guide](../lsp/README.md)); CI runs them in the `dexter` job against the freshly built binary. Changes to Codex launch arguments or generated Codex configuration also require the installed-Codex tests with `TIPS_TEST_REAL_CODEX=1`. CI has no Codex client: record the local result on the PR.

The reviewed `# noqa: S603` boundaries are `team.py:execute` and `StopAgentTest.client`: variable argument lists, no shell, resolved executable, fixed or test-owned arguments. These are per-call exceptions, not a disabled security rule. Suppress nothing else. When these calls change, the review covers trusted executable selection and arguments; passing lint cannot prove subprocess safety. Settings: [pyproject.toml](pyproject.toml).

When a pair fails the same way twice, fix the tool or its error message before adding a workflow rule.
