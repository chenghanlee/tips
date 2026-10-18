# Local development

Run commands from the repository root.

Install Elixir **1.20.4**, Erlang/OTP **29.1**, Python **3.12**, Docker with Compose, and a C build
toolchain (Xcode Command Line Tools on macOS, or a C compiler and `make` on Linux)
for native dependencies such as `lazy_html`. Python runs the image parser, documentation
checks and optional agent tooling. `mix setup` and `mix test` run `mix image_parser.setup`,
which installs Pillow into `_build/image_parser` from hash-pinned wheels for CPython 3.12,
or 3.14 on Apple Silicon. On macOS, the parser also needs `timeout` from Homebrew
`coreutils`. [Version sources](toolchain.md#version-sources) lists
all dependency, asset and image pins. Start the shared extension-enabled PostgreSQL
server from the main checkout with `docker compose up -d --wait db`.
Wait for a successful health check before running database setup or migrations.

From a fresh checkout:

```sh
mix local.hex 2.5.1 --force
mix local.rebar --force
cp .env.example .env
```

The example selects the local Compose superuser on port 5433. Dev and test load
only the [provider settings](#provider-settings) from `.env` automatically. The
database and port settings come only from the exported environment
(`config/dev.exs`, `config/test.exs`, `config/runtime.exs`), so export them in
each new shell:

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

No provider credentials are needed to boot, test or use features that do not call
a provider. Development mail stays in the local Swoosh
mailbox at <http://localhost:4000/dev/mailbox>. Sign-in is passwordless, by
magic link; a session family is renewed and revoked together. Oban runs in the
same application and Repo with `media`, `embeddings`, and `maintenance` queues,
each with concurrency 1. Cron runs `Tips.Workers.ExpireRegistrations` every
minute on `maintenance` and `Tips.Workers.EmbedSearch` every minute on
`embeddings`. Without `OPENROUTER_API_KEY`, each `EmbedSearch` run fails while
any tip or review lacks a vector. `Tips.Workers.ExpireMedia` runs every minute on
`media` and retires expired staged videos. `Tips.Workers.SweepOrphanImages` runs Mondays at
04:00 UTC on `maintenance`; without the R2 settings it fails. The pruner keeps
finished jobs for seven days.
Tests use Oban's manual testing mode.

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

### Provider settings

Search, image and video providers use ten fixed names, listed with empty values in
`.env.example`: `OPENROUTER_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`, `R2_BUCKET`,
`R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_PUBLIC_URL`,
`CLOUDFLARE_STREAM_API_TOKEN`, `CLOUDFLARE_STREAM_CUSTOMER_CODE` and
`CLOUDFLARE_STREAM_SIGNING_KEY`.

In dev and test, `config/runtime.exs` reads these names from the file named by
`TIPS_PROVIDER_ENV_FILE` (default: the checkout's `.env`) and from the exported
environment. An exported value, even an empty one, wins over the file. After
editing the file, re-source it or unset the overriding export. A missing file or
empty values still boot the app. Other names in `.env` are
ignored here. A leading UTF-8 byte-order mark is ignored; a `.env` that exists but
cannot be read stops startup.

The loader never runs the shell. Each provider line must be `NAME=value`,
`NAME='value'` or `NAME="value"`, optionally prefixed by `export ` and followed by
` # comment`. Unquoted values may contain letters, digits and `_ . / : @ + = , % -`.
Quote anything else. Double-quoted values may not contain `$`, a backtick or `\`;
use single quotes instead. Values are single-line. A malformed provider line stops
startup with its file, line number and name, never its value.

Provider code requests a value when it needs it:

```elixir
Tips.ProviderConfig.fetch!("R2_BUCKET")
```

A missing or blank value raises an error naming the variable, never the value.
Features that do not need it keep working.

`Tips.ProviderConfig.mode/0` returns `:real` in dev. Tests return `:stub` even when
credentials are present, so provider code uses `Req.Test` stubs. Set
`TIPS_REAL_PROVIDERS=1` to select `:real` and run tests tagged `:real_provider`,
which `mix test` otherwise excludes. Opt in only with an explicit authorization to
call the external service. Production does not read `.env`; production secret
loading is separate deployment work.

### Isolated build caches

If the agent sandbox cannot write to shared Hex/Mix caches, use writable
cache directories for that shell. From the worktree root:

```sh
export HEX_HOME="$PWD/tmp/hex"
export MIX_HOME="$PWD/tmp/mix"
export MIX_XDG=0
export XDG_CACHE_HOME="$PWD/tmp/cache"
mix local.hex 2.5.1 --force
mix local.rebar --force
mix deps.get --check-locked
```

These directories are ignored. Keep the committed lockfile.

### Local application release

The Dockerfile builds the pinned Elixir/OTP release on Debian bookworm with the
C toolchain, then runs it as a non-root user in Debian slim. Docker
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
docker compose up -d --wait db
# Create this database once on a fresh volume:
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

### Agent tooling

Use the [pair workflow](../../agent/teams/README.md) for coordination and
[Dexter guide](../../agent/lsp/README.md) for builds, provisioning and navigation.

### Extension-enabled database

Run `docker compose up -d --wait db` from the main checkout to start the shared PostgreSQL
image with pgvector and pg_textsearch ([versions](toolchain.md#version-sources)). [Compose](../../compose.yaml) serves it on
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
See the [database image contract](toolchain.md#postgresql-image-and-extension-contract)
for build inputs and private-registry publication.

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

Use one Compose server, started from the main checkout, with `PGPORT=5433`.
Give each manual worktree a unique `TIPS_DB_SUFFIX`, development HTTP `PORT`
and `TIPS_TEST_PORT`. A launched pair client keeps the values `team.py`
exported for it in its own clone; do not replace them. Tests start their own endpoint on
`TIPS_TEST_PORT` (default 4002), including when browser tests are excluded.
Each checkout already has its own `deps/` and `_build/`, so install dependencies
in each worktree. Do not share or symlink those directories. For launched
clients, `team.py` exports `TIPS_PROVIDER_ENV_FILE` pointing at the main
checkout's `.env`, so no clone contains a copy; a manual worktree reads its own
`.env` unless you export that variable. Export a manual worktree's
database and port values in its shell.

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

### Local verification during the CI pause

The [pause policy](../../AGENTS.md#github-ci-pause) changes where checks run, not their
coverage. In addition to the file-specific checks in AGENTS, run the applicable
verification from the retained workflow files, using their PR path filters:

| Retained check | Local execution |
|---|---|
| Introduced-commit secret scan, every PR | Run Gitleaks as below, with redacted output. |
| Application steps in `checks.yml` (changes beyond Markdown and `agent/`) | `mix deps.get --check-locked`, the [application checks](../../README.md#test-changes), `mix assets.setup && mix assets.build`, migration rollback/reapply below, and the [full browser suite](#browser-tests-and-ci), including both pinned version checks. |
| Release job in `checks.yml` (any non-Markdown change) | `scripts/release_smoke.sh`; see [local application release](#local-application-release) for its exclusive resources and prerequisites. |
| `dexter.yml` path match | Use the pinned build and verification commands in that workflow: patched Go tests, build-script tests and real-daemon harness tests. Follow the [LSP build guide](../../agent/lsp/README.md#build); never replace another team's active binary. |
| `db-image.yml` path match | `scripts/db_smoke.sh`; see [extension-enabled database](#extension-enabled-database). Image publication stays paused. |

For migration rollback/reapply, use a disposable database with your own suffix and
`MIX_ENV=test`: `mix ecto.create && mix ecto.migrate && mix ecto.rollback --all && mix ecto.migrate`.
Never run this against another agent's or persistent development data. A check that
cannot run is reported as blocked, not silently removed. Hosting, artifact upload and
publication steps are not local verification and remain paused.

For secret scanning, use [Gitleaks 8.30.1](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1).
An existing binary can be used; otherwise download the matching platform archive and
checksums from that release, verify its SHA-256 and extract it into ignored
`tmp/gitleaks/`. This task-local provisioning does not require a machine install.
Before pushing, fetch the PR base and scan every introduced commit (for base `main`):

```sh
git fetch origin main
tmp/gitleaks/gitleaks git --redact --log-opts="origin/main..HEAD" .
```

Adjust the executable path for an existing binary. Keep output redacted; never publish
a detected secret. Record the tool version, base/head SHAs and result in the PR. This
does not scan uncommitted edits, so commit and scan them before pushing.

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
export PGPORT=5433 TIPS_DB_SUFFIX=_a TIPS_TEST_PORT=4031 MIX_ENV=test
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
ChromeDriver may instead be on PATH.

Browser tests live in `test/tips_web/features/`. They run in a 1280×800 window
(`config/test.exs`) unless a test resizes it. The smoke test,
`live_smoke_test.exs`, resizes to 390×844 and runs one connected registration
journey. It checks invalid-email correction, account creation, and compiled
input border/focus styles. Each test uses an isolated SQL sandbox; inserts are
rolled back and mail uses the Swoosh test adapter. The 390×844 viewport does not
prove responsive layout, keyboard traversal or mobile-browser behaviour.

During the [GitHub CI pause](../../AGENTS.md#github-ci-pause), run applicable checks
locally and retain logs/screenshots for independent review. There are no hosted run
artifacts to wait for. The retained `checks` workflow, when enabled, runs documentation validation,
introduced-commit secret scanning, locked dependencies, compilation with
warnings as errors, formatting, `mix credo --strict`, assets, migrations and the
full suite including these browser tests. It uses the pinned runtime, database
image and browser pair.

On browser assertion failures, Wallaby saves screenshots under `screenshots/`
(gitignored). CI uploads them as `browser-failure-screenshots`; inspect that
artifact and the `mix test --trace` logs from the failed run. Browser tests use
synthetic data only and need no production secrets.

#### Browser milestone coverage

Use LiveViewTest for normal server-side integration tests and Wallaby for
real-browser milestone checks. Keep browser sessions isolated for login and
draft races. Chrome needs its OS libraries, CA certificates, fonts, a writable
temporary profile directory and local process/loopback access. Run it as a
non-root user.

Check keyboard/focus, draft recovery, uploads and private video playback by hand
in Safari on macOS, Safari on a physical iOS device and Chrome on a physical
Android device. Record the OS, browser and device versions with the results.

Use dispatched events or the required button path to test drag reordering.
Use branded Google Chrome for real Stream playback: Cloudflare's
[player documentation](https://developers.cloudflare.com/stream/viewing-videos/using-the-stream-player/)
notes H.264 requirements.
