# Tips

Tips helps developers discover and share practical AI techniques and firsthand results.

## Quick start

Install the pinned Elixir/OTP versions, Docker with Compose, and a C build toolchain
listed in the [development guide](docs/development/local-development.md).
Start the shared database from the main checkout:

```sh
docker compose up -d db
```

In your development checkout:

```sh
cp .env.example .env
set -a
. ./.env
set +a
mix deps.get --check-locked
mix ecto.setup
mix assets.setup
mix assets.build
mix phx.server
```

Open <http://localhost:4000>. No provider credentials are needed for local setup.
For agent worktrees, use the [team launcher](agent/teams/README.md#start-and-assign)
to assign isolated databases and ports before starting development.

## Documentation

- [Development and testing](docs/development/local-development.md)
- [Agent teams: dispatch, handoff, review and cleanup](agent/teams/README.md)
- [Elixir LSP: build, configuration and acceptance](agent/lsp/README.md)
- [Toolchain](docs/development/toolchain.md)
- [Architecture](docs/design/software-architecture.md) and [product glossary](docs/design/glossary.md)
- [GitHub Project 15](https://github.com/users/chenghanlee/projects/15) and [issues](https://github.com/chenghanlee/tips/issues)

GitHub owns current requirements, task status, blockers and review evidence.
`docs/design/` holds current design contracts; `docs/development/` explains how to
work on the application. GitHub holds delivery planning and prerequisites.
`agent/teams/` owns orchestration; `agent/lsp/` owns agent language-server tooling.
Application source, tests, assets and configuration retain the Phoenix layout.
Historical reviews and retired experiments remain in Git history; references link
to their committed revisions. They are not current instructions or acceptance
evidence for later revisions.

## Where files belong

| Purpose | Location |
|---|---|
| Application code, configuration, assets and release resources | Phoenix's `lib/`, `config/`, `assets/`, `priv/`, `rel/` |
| Application tests and fixtures | `test/` |
| Agent coordination, configuration, tests and instructions | `agent/teams/` |
| Agent LSP wrapper, builds, patches, tests and instructions | `agent/lsp/` |
| Application/database maintenance commands | `scripts/`, `db/` |
| Current design and development documentation | `docs/design/`, `docs/development/` |

Keep maintained tests with their owner. Put disposable experiment output in the
ignored `tmp/` directory or outside the repository. Framework/client-managed
directories such as `_build/`, `deps/`, `.codex/` and `.claude/` retain their expected
locations; they are not source folders to reorganize.
