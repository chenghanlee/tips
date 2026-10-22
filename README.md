# Tips

Tips helps developers find and share practical AI techniques and firsthand results.
Since 2026-10-21 it is being rebuilt from scratch, one thin vertical slice at a time.
The pre-restart code is at tag `archive/waterfall-2026-10-21`. Stack: Elixir/Phoenix
with PostgreSQL.

## Run the app

You need Elixir 1.20, Erlang/OTP 29 and Docker.

1. Start the shared database with `docker compose up -d` from the main checkout, never
   from a worktree. Every checkout shares the one service on port 5433.
2. Run `mix setup`. It fetches the dependencies, creates and migrates the database, and
   installs and builds the assets.
3. Run `mix phx.server` and open http://localhost:4000.

The config reads these environment variables:

| Variable | Default | Use |
|---|---|---|
| `PGHOST` | `localhost` | Database host |
| `PGPORT` | `5433` | Database port |
| `PGUSER`, `PGPASSWORD` | `postgres` | Database login |
| `TIPS_DB_SUFFIX` | empty | Appended to the `tips_dev` and `tips_test` database names |
| `PORT` | `4000` | Dev server port |
| `TIPS_TEST_PORT` | `4002` | Test endpoint port |

## Test changes

Start the database as above, then run these checks from your development checkout:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test
python3 scripts/check_docs.py
```

`mix test` creates and migrates the test database first. The first `mix dialyzer` run
builds its PLT in `_build/plts` and takes a few minutes. During the
[GitHub CI pause](AGENTS.md#github-ci-pause), run applicable checks locally and record their
evidence for independent review. Follow [AGENTS.md](AGENTS.md) for engineering rules.
Put the task scope, acceptance criteria and review evidence in the relevant GitHub issue and PR.

## Use agents (optional)

- [Agent pairs](agent/teams/README.md): a dispatcher starts one developer and one tester
  per issue; [setup](agent/teams/SETUP.md) covers prerequisites and configuration.
- [Elixir language server](agent/lsp/README.md): one shared Dexter server per checkout,
  used as a CLI by Claude and Codex.

Agent tooling is separate from the application. You do not need it to run Tips.
Pairs run with `MIX_ENV=test` and set `PGPORT`, `TIPS_DB_SUFFIX` and `TIPS_TEST_PORT`
so each pair has its own database and port. The config reads them as the table in
[Run the app](#run-the-app) shows; keep that when changing the config.

## Find requirements and tasks

- [PRODUCT.md](PRODUCT.md): purpose, audience, first scenario and principles.
- [GitHub Project 15](https://github.com/users/chenghanlee/projects/15): task planning and progress.
- [GitHub issues](https://github.com/chenghanlee/tips/issues): scope, acceptance criteria and blockers.
- [Design docs](docs/design/README.md): the requirement sections; the index grows with each slice.

## Where files belong

| Location | Purpose |
|---|---|
| `scripts/`, `db/` | Maintenance commands and the database image |
| `docs/design/` | Current product and technical requirements |
| `design/<brief>/` | Approved UX candidates: reference images, prompts and `candidate.md` per story ([UX design team](agent/teams/README.md#ux-design-team)) |
| `agent/skills/` | Shared, versioned skills for Codex and Claude |
| `agent/teams/` | The pair workflow, its scripts, configuration and tests |
| `agent/lsp/` | Agent language-server build script and local patch |

Dexter's binary lives in ignored `agent/lsp/dexter/vendor/`; shared Elixir sources live in
`agent/lsp/vendor/`. Dexter stores its per-checkout index and bound commands in `.dexter/`.

Keep root files in their standard locations for Mix, Git and Docker. Put disposable output
in ignored `tmp/` or outside the repository. Leave generated and client-managed folders,
such as `_build/`, `deps/`, `.codex/` and `.claude/`, in their expected locations.
