# Tips

Tips helps developers find and share practical AI techniques and firsthand results.
It is an Elixir/Phoenix application with PostgreSQL.

The app has a placeholder home page, read-only tip and review pages, passwordless
magic-link sign-in, session-family management, admission and content/search foundations,
scheduled registration-cleanup and search-embedding jobs and a database health check.
The Content context can publish, edit and delete text and let moderators hide or
restore it; no web screens use these yet.
The design documents describe target product behavior; GitHub issues and PRs track
what has been implemented.

## Run the app

Follow the [local development guide](docs/development/local-development.md) to:

1. Install the required tools.
2. Start the shared database from the main checkout.
3. Set up your checkout, environment and dependencies.
4. Start Phoenix and open <http://localhost:4000>.

Local setup needs no external provider credentials. If you use multiple
worktrees, follow the [worktree setup](docs/development/local-development.md#isolated-worktrees)
to give each checkout its own database and port.

The [toolchain guide](docs/development/toolchain.md) identifies version sources,
dependency choices and upgrade rules.

## Test changes

After setup, run these checks from your development checkout:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
python3 scripts/check_docs.py
```

`mix test` excludes browser tests. Follow the
[browser test instructions](docs/development/local-development.md#browser-tests-and-ci)
when a change needs browser coverage. CI runs the full suite, including browser tests.
A PR that changes only Markdown skips CI's application and release steps.

Follow [AGENTS.md](AGENTS.md) for engineering rules. Put the task scope, acceptance
criteria and review evidence in the relevant GitHub issue and PR.

## Use agents (optional)

- [Agent pairs](agent/teams/README.md): a dispatcher starts one developer and one tester
  per issue; [setup](agent/teams/SETUP.md) covers prerequisites and configuration.
- [Elixir language server](agent/lsp/README.md): one shared Dexter server per worktree,
  used as a CLI by Claude and Codex.

Agent tooling is separate from the application. You do not need it to run Tips.

## Find requirements and tasks

- [GitHub Project 15](https://github.com/users/chenghanlee/projects/15): task planning and progress.
- [GitHub issues](https://github.com/chenghanlee/tips/issues): scope, acceptance criteria and blockers.
- [Architecture](docs/design/software-architecture.md): system boundaries and deployment.
- [Backend design](docs/design/backend-design.md): operations, permissions and integrations.
- [Frontend design](docs/design/frontend-design.md): pages, forms and browser behavior.
- [Data model](docs/design/data-model.md): schema and database rules.
- [Glossary](docs/design/glossary.md): product terms.

## Where files belong

| Location | Purpose |
|---|---|
| `lib/`, `config/`, `assets/`, `priv/` | Application code, configuration and resources |
| `test/` | Application tests and fixtures |
| `rel/` | Scripts packaged into application releases |
| `scripts/`, `db/` | Maintenance commands and the database image |
| `docs/development/` | Setup, testing and toolchain guides |
| `docs/design/` | Current product and technical requirements |
| `agent/skills/` | Shared, versioned skills for Codex and Claude |
| `agent/teams/` | The pair workflow, its scripts, configuration and tests |
| `agent/lsp/` | Agent language-server build script and local patch |

Dexter's binary lives in ignored `agent/lsp/dexter/vendor/`; shared Elixir
sources live in `agent/lsp/vendor/`.

Keep root files in their standard locations for Mix, Git and Docker.
Put disposable experiment output in ignored `tmp/` or outside the repository.
Dexter stores its per-worktree index and bound commands in `.dexter/`.

Leave generated and client-managed folders, such as `_build/`, `deps/`, `.codex/`
and `.claude/`, in their expected locations.
