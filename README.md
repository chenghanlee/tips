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
through the TLS-terminating proxy with `X-Forwarded-Proto: https`. The release
also exempts `/healthz` from HTTP redirects for direct probes. It checks app/DB
liveness only; optional providers and background progress are not readiness gates.

If an agent sandbox cannot write the shared Hex/Mix caches, use the isolated
cache environment in the [toolchain instructions](docs/implementation/toolchain.md#disposable-generator-evidence)
before running Mix commands.

### Local application release

The Dockerfile builds the pinned Elixir/OTP release on Debian bookworm with the
C toolchain for bcrypt, then runs it as a non-root user in Debian slim. Docker
Compose publishes the app only on `127.0.0.1:4300` and the database on
`127.0.0.1:5433` (`TIPS_APP_PORT` / `TIPS_DB_PORT` override those host ports).
`PHX_HOST` defaults to `localhost`; the smoke sets `tips.example` to test the
public hostname and canonical HTTPS redirect.

Generate a local secret in each shell before running the app; never commit it.
The app's runtime configuration requires it, while DB-only commands do not.
If it is unset, the app container exits; `docker compose logs app` reports
`environment variable SECRET_KEY_BASE is missing`:

```sh
export SECRET_KEY_BASE=$(mix phx.gen.secret)
export RELEASE_REVISION=$(git rev-parse HEAD)
docker compose build app
docker compose up -d db
# Once the DB is healthy, create this database once on a fresh volume:
docker compose exec db psql -U postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE tips_release'
docker compose run --rm app bin/migrate
docker compose up -d app
curl --include --fail http://localhost:4300/healthz
docker compose restart app
docker compose logs -f app
```

Migrations are explicit and idempotent; app startup does not run them or create
the database. `Tips.Release` uses `Ecto.Migrator.with_repo` in a separate release
VM. Ecto migration transactions and DDL use infinite timeouts; the request Repo
retains its two-second timeout. The initial extension migration needs superuser
privileges, provided by the local container's `postgres` role. These Compose
credentials are for local use; hosting, TLS termination, and production database
provisioning are separate deployment work.

Run the acceptance test with Docker, Bash, curl, and OpenSSL installed:

```sh
scripts/release_smoke.sh
```

It builds and labels the image with the Git revision, prints its content-addressed
image ID, creates and migrates a fresh DB, checks direct/proxy health and HTTPS
redirects, stops the DB to assert a 503 within three seconds, replaces the DB container (discarding anonymous volumes), and restarts the app to
verify committed migrations persist. It generates an ephemeral secret when unset.
It exclusively uses Compose project `tips-release-smoke` on ports 5437/4300 and
removes that project's containers and volume on exit. Run one smoke at a time;
stop a local release app using port 4300 first. It never resets the shared
Compose database. CI runs this same test in the parallel `release` job with
Docker layer caching. `--skip-build` is for an already-built image whose revision
label matches `RELEASE_REVISION`, as used by CI.

### Elixir tooling for Codex

Use [Expert](https://github.com/expert-lsp/expert) for language-server features
and [Credo](https://github.com/rrrene/credo) for linting. Credo is a development
and test dependency; run `mix credo --strict` to include suggestions.
The local Codex configuration enables the `mix-compile` and `mix-credo` plugins.
The Credo hook checks edited `.ex`/`.exs` files with the project's configuration;
review its feedback and fix findings introduced by your edits.

The launcher `scripts/elixir_lsp.sh` connects a patched Expert to Codex or Claude
through [mcp-language-server](https://github.com/isaacphi/mcp-language-server).
Build and install both local patches using the
[LSP build instructions](docs/implementation/elixir-lsp-startup.md#build-and-validate).
Task worktrees share the binaries, with a separate LSP process per client.
The team helper generates the selected client's config from
[agent-team.toml](config/agent-team.toml). Coordinators run without Elixir LSP.

The client starts Expert before its first tool call; it can read and plan while
Expert builds and indexes. Check the real client and LSP roots in the disposable
pilot after launcher/tooling changes. `mcp get` alone checks registration, not the
running workspace. Expert logs are in the assigned worktree's `.expert/`.

Use `definition`, `references`, and `hover` with `filePath`, `line`, and `column`
at a call site. Lines and columns are 1-based; columns count UTF-16 code units.
Each tool synchronizes the latest file contents, including files already opened
by earlier calls, then sends the corresponding native LSP request. Navigation skips
unchanged contents using a hash of the last successful send. Diagnostics explicitly
refreshes the document even when unchanged so it can wait for another publication.
`rename_symbol` uses the same positive integer coordinate validation. Empty hover
results include the current source line even when the file has no final newline.

Definitions return unique source locations with labeled previews: at most 40
lines per location, sharing an 8 KiB source-preview budget per response. A preview
may include neighboring code; it is not a reconstructed implementation boundary.
Unavailable source or exhausted preview space does not hide resolved locations.

References return unique locations from the project selected by the source file.
Use an application call site to find application usages of a dependency. Other
projects may contain additional usages. Neither navigation tool depends on
workspace symbol search. The patched server distinguishes successful empty results from an index that is
not ready or a symbol it cannot resolve; those outcomes are reported as errors.

After rebuilding the bridge, restart Codex to load the new tool schema and binary.
Expert omits the optional document version from diagnostic publications. Routine
results therefore say "Latest published diagnostics" without a missing-version
notice. The bridge still synchronizes the file and waits for a new publication,
but cannot certify an exact edit match when no version is provided. Supplied
versions are checked; timeouts still report that the last list may be stale.
The same limitation is documented in the diagnostics tool description.

The Elixir and Erlang executables must be on Codex's `PATH`. Expert uses its
own user cache and local Erlang processes, so a sandboxed shell can require
additional access even when the MCP connection works.

For local agent teams, use Python 3.11 or newer, Git and Herdr. Launch settings
live in [config/agent-team.toml](config/agent-team.toml). From the main checkout:

```sh
scripts/team.py start 1
scripts/task_worktree.py 36-ci --team 1 --role dev --pane "$DEV_PANE" --start
```

Use the pane ID printed by the team launcher. Coding clients start in separate
worktrees with their configured environment and their own Expert instance.
The helper reuses an existing issue branch and writes only the selected client's
config. It refuses conflicting assignments or config; inspect those before using
`--force`. After merge, `scripts/team.py stop 1` checks shutdown and clean,
integrated work before removing resources. Follow the
[dispatch workflow](docs/implementation/goal-prompt.md#start-and-assign) and
[LSP build instructions](docs/implementation/elixir-lsp-startup.md#build-and-validate).

The launcher uses the caller's `$PWD` as the workspace and finds binaries in
the main checkout's `.elixir-tools/bin` through Git's common directory.
`TIPS_ELIXIR_TOOLS` can override the tools directory (the directory containing
`bin`); no per-worktree install is needed. Install Mix dependencies separately
in each worktree as described below. The downloaded tools, indexes, skills and
local Codex configuration are gitignored. The existing `codex-lsp-bridge`
supports other languages; use `elixir-lsp` for Elixir.

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
unique `TIPS_DB_SUFFIX`, development HTTP `PORT`, and `TIPS_TEST_PORT`;
use `PGPORT=5433` for the shared server. Tests start their own endpoint on
`TIPS_TEST_PORT` (default 4002), including when browser tests are excluded.
Each checkout already has its own `deps/` and `_build/`, so install dependencies
in each worktree. Do not share or symlink those directories. Phoenix loads no
`.env` automatically; export the worktree's values in its shell.

For example, after creating two worktrees at the revision to test:

```sh
# Terminal A, in .worktrees/a
export TIPS_DB_SUFFIX=_a PGPORT=5433 PORT=4001 TIPS_TEST_PORT=4031
mix deps.get --check-locked
mix test

# Terminal B, concurrently in .worktrees/b
export TIPS_DB_SUFFIX=_b PGPORT=5433 PORT=4002 TIPS_TEST_PORT=4032
mix deps.get --check-locked
mix test
```

These runs migrate `tips_test_a` and `tips_test_b` independently. Verify both
with `psql -h 127.0.0.1 -p 5433 -U postgres -l`. `mix ecto.setup` and
`mix phx.server` in those shells use `tips_dev_a`/`tips_dev_b` and HTTP ports
4001/4002. `MIX_TEST_PARTITION` can further partition each test database.
Only reset your own suffixed database. Do not reset another worktree's database
or run `docker compose down -v`, which destroys the shared server's data.

### Browser tests and CI

`mix test` excludes tests tagged `:browser`. To include them, install matching
Chrome for Testing and ChromeDriver **153.0.8010.52** outside the repository from
the [Chrome for Testing downloads](https://googlechromelabs.github.io/chrome-for-testing/153.0.8010.52.json).
Select your platform's `chrome` and `chromedriver` archives, extract both, and
set the executable paths below. Headless Chrome runs with its sandbox enabled;
no Xvfb or provider credentials are needed.

Ubuntu 23.10+ restricts user namespaces for downloaded Chrome binaries. CI loads
an AppArmor profile granting `userns` to the exact installed Chrome path so its
sandbox can start. Local Ubuntu installations need the same
[binary-specific allowance](https://chromium.googlesource.com/chromium/src/+/main/docs/security/apparmor-userns-restrictions.md).

Wallaby starts in `Tips.FeatureCase` setup so ordinary tests need no browser
installation; starting it in `test_helper.exs` would validate Chrome even when
all browser tests are excluded.

From a task worktree with its own dependencies and build directory:

```sh
export PGPORT=5433 TIPS_DB_SUFFIX=_36 TIPS_TEST_PORT=4036 MIX_ENV=test
export TIPS_CHROME_BINARY='/absolute/path/to/chrome'
export TIPS_CHROMEDRIVER='/absolute/path/to/chromedriver'
"$TIPS_CHROME_BINARY" --version
"$TIPS_CHROMEDRIVER" --version
mix deps.get --check-locked
mix assets.setup
mix assets.build
mix test --include browser --trace
# Or select only the smoke tests:
TIPS_BROWSER=1 mix test test/tips_web/features/live_smoke_test.exs --trace
```

Both version commands must report `153.0.8010.52`. On macOS the browser
executable is inside `Google Chrome for Testing.app/Contents/MacOS/`.
ChromeDriver may instead be on PATH. The browser smoke checks connected
LiveView email validation at 1280×800, the registration form at 390×844, and
registration through the connected LiveView. Each browser test has an isolated
SQL sandbox; inserts are rolled back and mail uses the Swoosh test adapter.
The narrow viewport checks layout in Chrome, not a physical mobile browser.

The required `checks` CI job preserves documentation validation and adds
introduced-commit secret scanning, locked dependencies, compilation with
warnings as errors, formatting, assets, migrations and the full suite including
these browser tests. It uses the pinned runtime, database image and browser
pair. Credo in CI is tracked separately in issue #153.

On browser assertion failures, Wallaby saves screenshots under `screenshots/`
(gitignored). CI uploads them as `browser-failure-screenshots`; inspect that
artifact and the `mix test --trace` logs from the failed run. These smoke tests
use synthetic accounts only and need no production secrets.
