# Tips

Tips helps developers discover and share practical AI techniques and firsthand results.

The project is currently in design and implementation planning. No application or real-provider milestone has passed yet.

- [Implementation plan](docs/implementation/implementation-plan.md)
- [Agent workflow and review policy](docs/implementation/agent-workflow.md)
- [Task catalogue](docs/implementation/task-index.md)
- [GitHub issues](https://github.com/chenghanlee/tips/issues)
- [Tips project](https://github.com/users/chenghanlee/projects/15)
- [Architecture](docs/design/technical/software-architecture.md)

GitHub is the live task tracker. The task catalogue links to the originally published issues; use GitHub for current requirements, dependencies and status. Historical experiments under `docs/brainstorm` are not current implementation or acceptance evidence.

## Setup

The Phoenix skeleton includes generated authentication, local email previews, Oban
and a database health endpoint. Product-specific authentication and provider
integrations are separate tasks.

Install Elixir **1.20.4**, Erlang/OTP **29.1**, Docker with Compose, and a C build
toolchain (Xcode Command Line Tools on macOS, or a C compiler and `make` on Linux)
for the generated bcrypt dependency. See the [toolchain decision](docs/implementation/toolchain.md)
for all dependency and asset pins. Start the shared extension-enabled PostgreSQL
**18.6** server from the main checkout with `docker compose up -d db`.

From a fresh checkout:

```sh
mix local.hex 2.5.1 --force
cp .env.example .env
```

The example selects the local Compose superuser on port 5433. Phoenix does not
load `.env` automatically. Export it in each new shell:

```sh
set -a
. ./.env
set +a

mix deps.get --check-locked
mix ecto.setup
mix assets.setup
mix assets.build
mix compile --warnings-as-errors
mix format --check-formatted
mix test
python3 scripts/check_docs.py
mix phx.server
```

Open <http://localhost:4000>. `PORT` changes the local port; `PHX_HOST` is used by
the generated production configuration. The commands create `tips_dev` and
`tips_test`, including generated auth tables, Oban schema version 14 and both
search extensions. `TIPS_DB_SUFFIX` is appended to both database names; test
partitioning adds `MIX_TEST_PARTITION` after that suffix when set.

No provider credentials are needed. Development mail stays in the local Swoosh
mailbox at <http://localhost:4000/dev/mailbox>. Generated authentication is the
unmodified Phoenix baseline; it does not yet implement Tips admission or session
rules. Oban runs in the same application and Repo with `media`, `embeddings`, and
`maintenance` queues, each with concurrency 1. There are no workers yet. Tests
use Oban's manual testing mode.

With the server running, check both routes from a second shell (adjust the port
if you changed it):

```sh
curl --fail http://localhost:4000/
curl --include --fail http://localhost:4000/healthz
```

`/healthz` returns exactly `{"status":"ok"}` with HTTP 200 when a read-only
`SELECT 1` succeeds, or `{"status":"error"}` with HTTP 503 when it fails. The
entire probe has a one-second deadline; both responses use `cache-control: no-store` and
contain no diagnostics. Production monitoring uses the public HTTPS hostname
through the TLS-terminating proxy; release and proxy setup belong to P0.05.

If an agent sandbox cannot write the shared Hex/Mix caches, use the isolated
cache environment in the [toolchain instructions](docs/implementation/toolchain.md#disposable-generator-evidence)
before running Mix commands.

### Extension-enabled database

Run `docker compose up -d db` from the main checkout to start the shared PostgreSQL
18.6 image with pgvector 0.8.6 and pg_textsearch 1.4.0. [Compose](compose.yaml) serves it on
`127.0.0.1:5433` with the local-only user/password `postgres`/`postgres` and
persists data in a named volume. `docker compose down` preserves that data.
Development and tests default to this port (`PGPORT=5433`). Migrations create
both extensions using the Compose superuser. The reference machine's Homebrew
server on 5432 has neither extension; `PGPORT=5432` is not a supported `mix test`
path. Deployment must use this same pinned image; production continues to select
its database with `DATABASE_URL`.

Run `scripts/db_smoke.sh` to build the same recipe and verify real BM25 and
1024-dimension vector queries in a disposable container. It publishes no port,
so it can run while Compose is up, and removes its container and volume on exit.
See the [database image contract](docs/implementation/toolchain.md#postgresql-image-and-extension-contract)
for pins, package checksums, CI evidence and private-registry publication.

Ordinary Repo queries have a two-second client timeout. A timeout disconnects
that pool connection. Use `Tips.Repo.maintenance_query!(sql, params, opts)` for
maintenance SQL: it defaults to `timeout: :infinity` for that call only and
honors an explicit longer or shorter timeout. It changes no connection setting.
Ecto migrations already use `timeout: :infinity` for transactions and DDL.

`mix ecto.drop` and `mix ecto.reset` work in development and test. Under
`MIX_ENV=prod`, both refuse to run unless `TIPS_ALLOW_RESET=1` is explicitly set,
including when `--force` is passed. This guard runs before runtime configuration
or a database connection. The override permits the task to proceed; Ecto still
asks for confirmation unless `--force` is supplied. Do not export this override
in normal setup. Releases do not include Mix.

### Isolated worktrees

Use one Compose server, started from the main checkout. Give each worktree a
unique `TIPS_DB_SUFFIX` and HTTP `PORT`; use `PGPORT=5433` for the shared server.
Each checkout already has its own `deps/` and `_build/`, so install dependencies
in each worktree. Do not share or symlink those directories. Phoenix loads no
`.env` automatically; export the worktree's values in its shell.

For example, after creating two worktrees at the revision to test:

```sh
# Terminal A, in .worktrees/a
export TIPS_DB_SUFFIX=_a PGPORT=5433 PORT=4001
mix deps.get --check-locked
mix test

# Terminal B, concurrently in .worktrees/b
export TIPS_DB_SUFFIX=_b PGPORT=5433 PORT=4002
mix deps.get --check-locked
mix test
```

These runs migrate `tips_test_a` and `tips_test_b` independently. Verify both
with `psql -h 127.0.0.1 -p 5433 -U postgres -l`. `mix ecto.setup` and
`mix phx.server` in those shells use `tips_dev_a`/`tips_dev_b` and HTTP ports
4001/4002. `MIX_TEST_PARTITION` can further partition each test database.
Only reset your own suffixed database. Do not reset another worktree's database
or run `docker compose down -v`, which destroys the shared server's data.
