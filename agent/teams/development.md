# Changing agent/teams scripts

## Required checks

For Python changes in `agent/teams`, run these checks locally under the
[CI pause policy](../../AGENTS.md#github-ci-pause). The retained `checks` workflow uses
the same commands:

```sh
python -m pip install --require-hashes --no-deps -r agent/teams/requirements.lock
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

Run these commands in your checkout once, at the PR head, before the push that opens
or updates the PR. Per commit, run only `ruff check`, `ruff format --check` and the
test module you changed. If a tool is missing, use an available task-local environment
or report the prerequisite; do not fall back to paused CI. Use the locked environment
below instead of the first line: `pyright --pythonpath agent/teams/.venv/bin/python
--project agent/teams/pyproject.toml`, and run the tests with
`agent/teams/.venv/bin/python`. With another Python the adapter tests are skipped and
say so. To run one module, give its file name as the pattern, for example
`-p test_pr_review.py`.

The serial suite takes 4 to 5 minutes. The parallel runner splits it over worker
processes and reports the combined result; it is the same suite, so it counts as the
full run:

```sh
env -u MIX_ENV agent/teams/.venv/bin/python agent/teams/tests/parallel.py
```

`-j N` sets the worker count (default: the CPU count) and `-k SUBSTRING` selects tests
by id. Tests whose id contains `real_` share ports, so they run in one worker. On a
loaded machine, lower `-j`.

If Ruff or Pyright is missing, provision check tools in an ignored environment using
the existing CI pins (not the adapter's runtime lock or a machine-wide install):

```sh
python3.12 -m venv tmp/harness-checks
tmp/harness-checks/bin/python -m pip install ruff==0.16.8 pyright==1.1.413
tmp/harness-checks/bin/ruff check agent/teams
tmp/harness-checks/bin/ruff format --check agent/teams
tmp/harness-checks/bin/pyright --pythonpath agent/teams/.venv/bin/python --project agent/teams/pyproject.toml
```

An existing environment with those versions can be reused. A refused installation or
unavailable prerequisite is a blocker; no fallback to paused CI or permission bypass.

Run these additional tests for the listed changes:

| Change | Required tests | Execution and evidence |
|---|---|---|
| Non-Markdown `agent/teams/` changes | Real-daemon tests (`-k real_daemons`), with `TIPS_TEST_REAL_DEXTER` and `DEXTER_ELIXIR_LIB_ROOT` set. Follow the [Dexter verification scope](../lsp/README.md#verification-scope). | Check the selected binary's identity, run locally and record the result. Harness-only changes do not require Dexter's internal Go or build-script suite. |
| Codex launch arguments | Installed-Codex tests, with `TIPS_TEST_REAL_CODEX=1`. | Run locally and record the result on the PR. CI has no Codex client. |
| Dispatcher launch arguments or adapter tools | The real restricted client with the launcher's arguments against a disposable copy, fake `gh` and a refusing fake `herdr`: it lists only the adapter tools and a read tool works. | Run locally and record the transcript summary on the PR. CI has no Claude client. |

### Additional local analyzers

CI does not run these. Run them before pushing and fix or record each finding. They are
not in the locked `.venv`; any environment with them will do. Versions used today: mypy
2.3.1, pylint 3.3.9, bandit 1.9.4, vulture 2.16, pip-audit 2.10.1, shellcheck 0.11.0. Run the
first four from `agent/teams`, the last two from the repository root:

```sh
mypy --python-executable .venv/bin/python --strict --warn-unreachable --ignore-missing-imports .
pylint --disable=all --enable=similarities --min-similarity-lines=10 --ignore-comments=y --ignore-docstrings=y --ignore-imports=y *.py tests/*.py
bandit -q -r . -x ./tests,./.venv
vulture . --min-confidence 60 --exclude .venv
pip-audit -r agent/teams/requirements.lock --require-hashes --disable-pip --strict
shellcheck agent/teams/dispatch
```

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
  Fixture directories live in the checkout's ignored `tmp/team-tests/`, not in a temporary
  directory, because the harness root refuses temporary directories.
  Never use live pairs in tests.
- [tests/harness.py](tests/harness.py) holds the shared fixtures: the fixture
  configuration, the fake programs and the `Harness` base class. Test modules import
  them from there. Test what one function decides in-process, as `ObserveTest` does; keep
  a `Harness` test for behaviour that needs a started pair.
- The fake Herdr injects launch faults on request: a killed launcher, a start timeout,
  a client that exits, a second concurrent `team.py`. Use these instead of sleeps.
- The harness root, with its records and lock, must be on a local filesystem: `team.py` relies
  on `flock`, atomic rename and `fsync`.
- Tests need permission to run `ps` and send signals to their own child processes.

## Lint exceptions

The reviewed `# noqa: S603` exceptions apply only to `commands.py:execute`,
`StopAgentTest.client`, the namer that `dispatcher.py:start_here` starts and the two
concurrent launchers in `DispatchTest`. These calls use variable argument lists, no
shell, a resolved or test-owned executable, and fixed, caller-supplied or test-owned
arguments. The `# noqa: S606` in `start_here` replaces
the launcher with the resolved `claude` executable and its fixed arguments, so the
client is the pane's foreground process. The `# noqa: S108` exceptions apply only to
`config.py:TEMPORARY`, the temporary-root list in `config.py:temporary_roots`, and the
refused roots in
`PairLifecycleTest.test_a_root_in_the_checkout_or_a_temporary_directory_is_refused` and
`ClaimRootTest.test_a_root_inside_the_checkout_a_temporary_directory_or_a_symlink_is_refused`.
They name temporary directories to refuse them; nothing is written there.
The `PT027` per-file ignore for `tests/**` allows `assertRaises`: the suite is unittest
by design, and CI runs `python -m unittest`.

When changing any of these calls, review the executable selection and arguments for
safety. Lint does not verify their safety. Do not suppress other warnings.

Lint and type-check settings are in [pyproject.toml](pyproject.toml).

## Repeated failures

If the same failure occurs twice during a pair's work, fix the tool or its error
message before adding a workflow rule.

## Trial measurement

Inspect actual decisions, code and correctness/design review alongside elapsed time,
waits and repair work. Include every participant, including dispatcher and
designers. `board.py usage` (the dispatcher's `usage_summary`) separates uncached input,
output, cache reads and writes. Counts cover whole sessions: compare before/after totals
when sessions are reused. Check coverage and category overlap before converting counts
to costs; missing logs are unknown, not zero cost.

Useful same-task context and stable role material can help reuse; session continuity
does not guarantee a cache hit. Do not retain stale context or unnecessary agents merely
to improve the hit rate. Use ordinary issue/PR evidence, without a new dashboard or
numeric quality score. A task with no structural decision is inconclusive about repair
authority; a passing test suite does not demonstrate better design judgment or efficiency.
