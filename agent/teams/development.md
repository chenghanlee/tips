# Changing agent/teams scripts

## Required checks

For Python changes in `agent/teams`, the required CI job `checks` runs:

```sh
python -m pip install --require-hashes --no-deps -r agent/teams/requirements.lock
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

Run these commands in your checkout before pushing if Ruff and Pyright are on
`PATH`. Otherwise, use CI. Locally, use the locked environment below instead of the
first line: `pyright --pythonpath agent/teams/.venv/bin/python --project
agent/teams/pyproject.toml`, and run the tests with `agent/teams/.venv/bin/python`.
With another Python the adapter tests are skipped and say so.

Run these additional tests for the listed changes:

| Change | Required tests | Execution and evidence |
|---|---|---|
| `bootstrap.py`, retirement or client stopping | Real-daemon tests (`-k real_daemons`), with `TIPS_TEST_REAL_DEXTER` and `DEXTER_ELIXIR_LIB_ROOT` set. See the [LSP guide](../lsp/README.md). | CI runs these in the `dexter` job against the newly built binary. |
| Codex launch arguments | Installed-Codex tests, with `TIPS_TEST_REAL_CODEX=1`. | Run locally and record the result on the PR. CI has no Codex client. |
| Dispatcher launch arguments or adapter tools | The real restricted client with the launcher's arguments against a disposable copy, fake `gh` and a refusing fake `herdr`: it lists only the adapter tools and a read tool works. | Run locally and record the transcript summary on the PR. CI has no Claude client. |

## Dependencies and test isolation

- Scripts use only the Python standard library, except [adapter.py](adapter.py). It
  needs the official MCP Python SDK, pinned with every transitive package and its hashes
  in [requirements.lock](requirements.lock) (about 30 packages). Create the locked
  environment from the repository root; it is Git-ignored:

  ```sh
  python3.12 -m venv agent/teams/.venv
  agent/teams/.venv/bin/python -m pip install --require-hashes --no-deps -r agent/teams/requirements.lock
  ```

  After changing `dependencies` in [pyproject.toml](pyproject.toml), regenerate the lock
  from `agent/teams`:
  `uv pip compile pyproject.toml --generate-hashes --python-version 3.12 --universal -o requirements.lock`.
- Tests use disposable Git repositories with a bare origin, fake Herdr, `gh`, Mix,
  `psql`, `ps` and Dexter executables, and child processes that the tests start and own.
  Fixtures live in the checkout's ignored `tmp/team-tests/`, not in a temporary
  directory, because the harness root refuses temporary directories.
  Never use live pairs in tests.
- The fake Herdr injects launch faults on request: a killed launcher, a start timeout,
  a client that exits, a second concurrent `team.py`. Use these instead of sleeps.
- The harness root, with its records and lock, must be on a local filesystem: `team.py` relies
  on `flock`, atomic rename and `fsync`.
- Tests need permission to run `ps` and send signals to their own child processes.

## Lint exceptions

The reviewed `# noqa: S603` exceptions apply only to `team.py:execute`,
`StopAgentTest.client` and the namer that `dispatcher.py:start_here` starts. These calls
use variable argument lists, no shell, a resolved executable, and fixed,
caller-supplied or test-owned arguments. The `# noqa: S606` in `start_here` replaces
the launcher with the resolved `claude` executable and its fixed arguments, so the
client is the pane's foreground process.

When changing any of these calls, review the executable selection and arguments for
safety. Lint does not verify their safety. Do not suppress other warnings.

Lint and type-check settings are in [pyproject.toml](pyproject.toml).

## Repeated failures

If the same failure occurs twice during a pair's work, fix the tool or its error
message before adding a workflow rule.
