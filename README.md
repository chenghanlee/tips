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

Install Elixir **1.20.4**, Erlang/OTP **29.1**, PostgreSQL **18.6**, and a C build
toolchain (Xcode Command Line Tools on macOS, or a C compiler and `make` on Linux)
for the generated bcrypt dependency. See the [toolchain decision](docs/implementation/toolchain.md)
for all dependency and asset pins. Start PostgreSQL on `localhost:5432` and use an
existing role with database-creation permission.

From a fresh checkout:

```sh
mix local.hex 2.5.1 --force
cp .env.example .env
```

Edit `.env` with your local PostgreSQL role and password. The reference machine
uses `PGUSER=chenghanlee` and an empty `PGPASSWORD`; it has no `postgres` role.
Phoenix does not load `.env` automatically. Export it in each new shell:

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
`tips_test`, including generated auth tables and Oban schema version 14. Test
partitioning appends `MIX_TEST_PARTITION` to `tips_test` when set.

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
