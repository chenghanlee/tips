# Tips

Tips helps developers find and share practical AI techniques and firsthand results.
Since 2026-10-21 it is being rebuilt from scratch, one thin vertical slice at a time.
The pre-restart code is at tag `archive/waterfall-2026-10-21`. Stack: Elixir/Phoenix with PostgreSQL.

## Run the app

There is no application yet; the first slice creates the Mix project and its setup guide.
Start the shared database from `compose.yaml` with `docker compose up -d`.

## Test changes

Once a Mix project exists, run these checks from your development checkout:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test
python3 scripts/check_docs.py
```

Until then, only `python3 scripts/check_docs.py` applies. During the
[GitHub CI pause](AGENTS.md#github-ci-pause), run applicable checks locally and record their
evidence for independent review. Follow [AGENTS.md](AGENTS.md) for engineering rules.
Put the task scope, acceptance criteria and review evidence in the relevant GitHub issue and PR.

## Use agents (optional)

- [Agent pairs](agent/teams/README.md): a dispatcher starts one developer and one tester per issue; [setup](agent/teams/SETUP.md) covers prerequisites and configuration.
- [Elixir language server](agent/lsp/README.md): one shared Dexter server per checkout, used as a CLI by Claude and Codex.

Agent tooling is separate from the application. You do not need it to run Tips.
Pair bootstrap needs a Mix project with a `mix.lock`, so slices before that run outside pairs.

## Find requirements and tasks

- [GitHub Project 15](https://github.com/users/chenghanlee/projects/15): task planning and progress.
- [GitHub issues](https://github.com/chenghanlee/tips/issues): scope, acceptance criteria and blockers.
- [Design docs](docs/design/README.md): the requirement sections; the index grows with each slice.

## Where files belong

| Location | Purpose |
|---|---|
| `scripts/`, `db/` | Maintenance commands and the database image |
| `docs/design/` | Current product and technical requirements |
| `agent/skills/` | Shared, versioned skills for Codex and Claude |
| `agent/teams/` | The pair workflow, its scripts, configuration and tests |
| `agent/lsp/` | Agent language-server build script and local patch |

Dexter's binary lives in ignored `agent/lsp/dexter/vendor/`; shared Elixir sources live in
`agent/lsp/vendor/`. Dexter stores its per-checkout index and bound commands in `.dexter/`.

Keep root files in their standard locations for Mix, Git and Docker. Put disposable output
in ignored `tmp/` or outside the repository. Leave generated and client-managed folders,
such as `_build/`, `deps/`, `.codex/` and `.claude/`, in their expected locations.
