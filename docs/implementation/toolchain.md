# Tips toolchain

This is the version decision for [P0.01](https://github.com/chenghanlee/tips/issues/22), dated 2026-09-21. Exact pins select inputs for probes; they do not certify the complete application. P16.00 owns SaladUI compatibility and P0.06 owns the combined database image and SQL proof.

## Runtime and generator

| Component | Exact selection | Status and primary source |
|---|---|---|
| Elixir | 1.20.4 | Pinned; installed locally. [Release](https://github.com/elixir-lang/elixir/releases/tag/v1.20.4) |
| Erlang/OTP | 29.1 | Pinned; local `OTP_VERSION` is 29.1. [Release](https://github.com/erlang/otp/releases/tag/OTP-29.1) |
| Hex | 2.5.1 | Pinned; installed locally. [Release](https://github.com/hexpm/hex/releases/tag/v2.5.1) |
| Phoenix installer / framework | 1.8.14 | Pinned. [Installer](https://hex.pm/packages/phx_new/1.8.14), [framework](https://hex.pm/packages/phoenix/1.8.14) |
| PostgreSQL | 18.6 | Pinned for the probe; local Homebrew server has no pgvector or pg_textsearch. [Release](https://www.postgresql.org/docs/18/release-18-6.html) |

Keep a single Phoenix application with PostgreSQL, Bandit, LiveView, Ecto, mailer and generated asset tooling. Retain integer primary keys. Run the generator outside this repository; do not commit generated application code in this task.

No `postgres` role exists on this dev machine: P0.02 ([#23](https://github.com/chenghanlee/tips/issues/23)) must read DB credentials from the environment, and P0.03 ([#31](https://github.com/chenghanlee/tips/issues/31)) must use the containerized database.

## Application dependencies

The matrix versions for generated dependencies come from the captured `mix.lock`, not the generator’s `~>` ranges. The committed lock enforces exact resolved versions, including transitive dependencies. “Pinned” means the selected version is exact; it does not mean all Tips behavior has passed. Keep the generator’s `~>` requirements in `mix.exs` and commit the application’s `mix.lock`. P0.04 ([#36](https://github.com/chenghanlee/tips/issues/36)) adds `mix deps.get --check-locked` to CI so pending lock changes fail the build. Reviewed upgrades use `mix deps.update` within those ranges and commit the updated lock. Keep exact downloaded asset-binary versions in config. Do not replace these with `latest`. The generated baseline's full lock is retained below so its transitive dependencies can be reproduced.

| Component | Exact selection and primary source | Status / evidence boundary |
|---|---|---|
| LiveView | [phoenix_live_view 1.2.12](https://hex.pm/packages/phoenix_live_view/1.2.12) | Pinned; generated suite passed; SaladUI interactions remain P16.00 |
| Ecto / Ecto SQL | [ecto 3.14.2](https://hex.pm/packages/ecto/3.14.2) / [ecto_sql 3.14.0](https://hex.pm/packages/ecto_sql/3.14.0) | Pinned; generated suite passed |
| PostgreSQL driver | [postgrex 0.22.4](https://hex.pm/packages/postgrex/0.22.4) | Pinned; local PG18 connection passed; extension queries remain P0.06 |
| Phoenix Ecto / HTML | [phoenix_ecto 4.7.0](https://hex.pm/packages/phoenix_ecto/4.7.0) / [phoenix_html 4.3.0](https://hex.pm/packages/phoenix_html/4.3.0) | Pinned; generated suite passed |
| HTTP server | [bandit 1.12.5](https://hex.pm/packages/bandit/1.12.5) | Pinned; generated dependency, no release/server load test here |
| Jobs | [oban 2.24.1](https://hex.pm/packages/oban/2.24.1) | Pinned, open integration risk; not installed in the generated baseline; requires Ecto SQL `~> 3.10`, Elixir `~> 1.15` |
| Tailwind | [tailwind 0.5.1](https://hex.pm/packages/tailwind/0.5.1) wrapper / [Tailwind CSS 4.3.0](https://github.com/tailwindlabs/tailwindcss/releases/tag/v4.3.0) binary | Pinned; generator config selects 4.3.0; full SaladUI styles remain P16.00 |
| JavaScript builder | [esbuild 0.10.0](https://hex.pm/packages/esbuild/0.10.0) wrapper / [esbuild 0.25.4](https://github.com/evanw/esbuild/releases/tag/v0.25.4) binary | Pinned; generator defaults |
| Generated component styles | [daisyui 5.5.20](https://github.com/saadeghi/daisyui/tree/v5.5.20), git `22ecff57f2c391b80a75617325748cf4d13fdf47`, sparse `packages/bundle` | Pinned in the captured lock. Keep through P0.02 because generated `core_components.ex` uses its classes and `app.css` loads its plugin; P16.00 removes it when SaladUI replaces core components |
| Icons | [heroicons 2.2.0](https://github.com/tailwindlabs/heroicons/tree/v2.2.0), git `0435d4ca364a608cc75e2f8683d374e55abbae26`, sparse `optimized` | Pinned in the captured lock; keep through P0.02 and the SaladUI migration |
| UI candidate | [salad_ui 1.0.0](https://hex.pm/packages/salad_ui/1.0.0) | Open-risk candidate; published requirements include LiveView `~> 1.2`, non-optional `igniter ~> 0.6`, `sourceror ~> 1.9` and `tw_merge ~> 0.1` (Elixir `~> 1.14`). P0.02/P16.00 must account for those installer and class-merging dependencies. P16.00 must prove hooks, errors, keyboard focus, patches and reconnect on this Tailwind/Phoenix combination |
| Markdown renderer | [mdex 0.13.5](https://hex.pm/packages/mdex/0.13.5) | Pinned; `mdex_native` needs a prebuilt NIF for each target platform. Darwin-arm64 worked in [Opus’s probe](https://github.com/chenghanlee/tips/pull/140#issuecomment-5751991242); other target platforms and full rendering fixtures remain open risks |
| HTML sanitizer | MDEx 0.13.5 built-in [`sanitize:` option](https://github.com/leandrocp/mdex/blob/v0.13.5/guides/safety.md), using Ammonia inside `mdex_native` | Selected with the renderer; no separate sanitizer package or custom scrubber. Local policy probe recorded below; full rendering fixtures and native platform support remain open integration risks |
| Browser driver | [wallaby 0.31.0](https://hex.pm/packages/wallaby/0.31.0) with `Wallaby.Chrome` | Pinned, open runtime risk until P0.04 ([#36](https://github.com/chenghanlee/tips/issues/36)) executes the smoke below |

The generator does not install Oban, SaladUI, MDEx or Wallaby. Their presence in this decision table is not a claim that this run compiled or exercised them together. No version combination is certified for Tips until the owning P16.00/P0.06 probes and feature checks pass.

## Disposable generator evidence

Run on 2026-09-21 (Asia/Manila), macOS arm64, outside the repository at `/private/tmp/tips-22-probe.hv43AG/tips_probe`. Database namespace: `tips_22_probe_hv43ag_test`; no provider namespace or credentials were used. The test endpoint stayed disabled, so no HTTP port was bound. Local PostgreSQL listens on 5432.

The following are the exact substantive commands and their results. Output was captured under the parent probe directory. The generator intentionally retained HTML, LiveView, Ecto, mailer and assets; `--no-install` makes dependency resolution and its failures visible separately.

```sh
# exit 0; creates /private/tmp/tips-22-probe.hv43AG outside the repo
mktemp -d /private/tmp/tips-22-probe.XXXXXX
cd /private/tmp/tips-22-probe.hv43AG
# exit 0; generated TipsProbe with PostgreSQL and Bandit
mix phx.new tips_probe --app tips_probe --module TipsProbe --database postgres --adapter bandit --no-install --no-agents-md --no-version-check
cd tips_probe
# exit 1: shared ~/.hex cache not writable in the agent sandbox
mix deps.get
# exit 1: Hex cache fixed, but Mix's automatic rebar3 install needed writable cache
HEX_HOME=/private/tmp/tips-22-probe.hv43AG/hex mix deps.get
```

The repair was to isolate caches, without changing the user's installed toolchain. The exact environment for all subsequent Mix commands was:

```sh
export HEX_HOME=/private/tmp/tips-22-probe.hv43AG/hex
export MIX_HOME=/private/tmp/tips-22-probe.hv43AG/mix
export MIX_ARCHIVES=/Users/chenghanlee/.mix/archives
export MIX_XDG=0
export XDG_CACHE_HOME=/private/tmp/tips-22-probe.hv43AG/cache
# exit 0; installed rebar3 and resolved/downloaded the lock below
mix deps.get
```

On another machine, use that machine's archive directory containing Hex 2.5.1 and phx_new 1.8.14. For a fresh install, `mix local.hex 2.5.1 --force` and `mix archive.install hex phx_new 1.8.14 --force` are the bootstrap commands; those installations were not needed or executed here. Change the temporary path and DB role to local equivalents. Restore the lock below before `mix deps.get` to repeat the captured dependency resolution.

The generated `postgres` DB role did not exist locally: `psql -h localhost -U postgres -d postgres -Atc 'select current_user'` exited 2. The existing local role worked (`psql -h localhost -U chenghanlee -d postgres -Atc 'select current_user'`, exit 0). Only disposable test configuration was adapted, with this command (exit 0):

```sh
python3 - <<'PY'
from pathlib import Path
p = Path('config/test.exs')
s = p.read_text().replace('username: "postgres"', 'username: "chenghanlee"').replace('password: "postgres"', 'password: ""').replace('tips_probe_test#{System.get_env("MIX_TEST_PARTITION")}', 'tips_22_probe_hv43ag_test#{System.get_env("MIX_TEST_PARTITION")}')
p.write_text(s)
PY
# exit 0; Generated tips_probe app (15 .ex files)
mix compile --warnings-as-errors
# exit 0; generated alias creates/migrates the isolated database, then runs ExUnit
mix test
```

Test output: `Running ExUnit with seed: 117011, max_cases: 20`, `Result: 5 passed`. These are `TipsProbeWeb.PageControllerTest` (GET `/`), `TipsProbeWeb.ErrorHTMLTest` (404/500), and `TipsProbeWeb.ErrorJSONTest` (404/500). Compilation/test emitted a dependency deprecation warning about `xref: [exclude: ...]` becoming `elixirc_options: [no_warn_undefined: ...]`; the commands still exited 0. This is not a warning-free dependency claim.

Additional asset checks: `mix assets.setup` exited 0 (downloaded Tailwind 4.3.0 and esbuild 0.25.4); `mix assets.build` exited 0 (`tailwindcss v4.3.0`, CSS built in 112 ms; JavaScript 327.5 kB, built in 25 ms). Output also identified the generated baseline’s daisyUI 5.5.20. This verifies generated assets only; it does not validate or choose daisyUI instead of the required SaladUI design.

Cleanup: `dropdb -h localhost -U chenghanlee tips_22_probe_hv43ag_test` exited 0. `psql -h localhost -U chenghanlee -d postgres -Atc "select count(*) from pg_database where datname = 'tips_22_probe_hv43ag_test'"` exited 0 and returned `0`. The temporary source/build files and logs are retained outside the repo for reviewer inspection; no database, server or provider resources remain from the probe.

During design repair, `mix deps.get --check-locked` ran in the retained disposable app with the isolated environment above: exit 0, `All dependencies have been fetched`; the lock SHA-256 stayed unchanged.

No ExUnit test or application code was added to Tips for this documentation probe. Repository check: `python3 scripts/check_docs.py` (exit 0, `PASS: local documentation links valid`). SQL extension, SaladUI, provider and real-device checks were not run.

## Browser decision

Use Wallaby inside ExUnit for real-browser milestone tests, with the existing Phoenix/Ecto sandbox integration. LiveViewTest remains the normal server-side integration test tool. Wallaby fits the existing Elixir stack and supports multiple isolated browser sessions for login and draft races.

Pin **Google Chrome for Testing and ChromeDriver 153.0.8010.52**, from Google's [known-good version manifest](https://github.com/GoogleChromeLabs/chrome-for-testing/blob/gh-pages/known-good-versions-with-downloads.json), using matching platform downloads. The local ordinary Chrome is 153.0.8010.48 and there is no `chromedriver` on PATH; neither substitutes for the pinned pair. The pins were checked in the manifest, not installed here.

System requirements: Chrome plus matching ChromeDriver on PATH; the Chrome binary path configured explicitly; OS libraries required by that Chrome build, CA certificates and fonts; a writable temporary profile directory; local process/loopback access. On Linux, use Google's packaged Chrome dependencies (GTK/ATK, NSS, GBM, ALSA and X11 libraries) on a supported distribution. Headless Chrome needs no Xvfb. Keep its sandbox enabled and run as a non-root user. Elixir/OTP and the Hex/Rebar build tools are needed for Wallaby. See the [pinned driver instructions](https://github.com/elixir-wallaby/wallaby/blob/v0.31.0/lib/wallaby/chrome.ex) and [Phoenix/Ecto integration setup](https://github.com/elixir-wallaby/wallaby/blob/v0.31.0/README.md#phoenix): endpoint `server: true`, test-only SQL sandbox plug, Wallaby `otp_app`/`base_url`, and `Application.ensure_all_started(:wallaby)`.

| Initial matrix | Execution and limitation |
|---|---|
| Pinned Chrome for Testing, Linux desktop, 1280×800 | Automated CI milestone path after browser setup; fresh and multiple sessions |
| Same Chrome, 390×844 viewport | Automated responsive smoke; resizing is not a claim of touch/mobile engine coverage |
| Safari on macOS and physical iOS Safari; Chrome on physical Android | Manual milestone checks for keyboard/focus, storage recovery, upload and private video playback; record exact OS/browser/device versions in gate evidence. Versions/access are open risks, not passed checks |

The standalone `Mix.install` command below selects the exact driver for this disposable smoke; application dependencies still use `~>` plus their committed lock.

Runnable standalone driver smoke after installing the pinned browser pair (outside the repo; set `TIPS_CHROME_BINARY` to the downloaded executable and put its ChromeDriver on PATH):

```sh
elixir -e '
Mix.install([{:wallaby, "== 0.31.0"}])
Application.put_env(:wallaby, :driver, Wallaby.Chrome)
Application.put_env(:wallaby, :chromedriver,
  binary: System.fetch_env!("TIPS_CHROME_BINARY"), headless: true)
{:ok, _} = Application.ensure_all_started(:wallaby)
{:ok, session} = Wallaby.start_session(window_size: [width: 1280, height: 800])
try do
  session = Wallaby.Browser.visit(session, "data:text/html,<h1>Tips%20browser%20smoke</h1>")
  true = Wallaby.Browser.has?(session, Wallaby.Query.css("h1", text: "Tips browser smoke"))
  IO.puts("PASS: Wallaby Chrome smoke")
after
  Wallaby.end_session(session)
end
'
```

Expected exit 0. **Not executed here:** ChromeDriver is absent. This command proves driver startup and DOM access only; P0.04 ([#36](https://github.com/chenghanlee/tips/issues/36)) owns this smoke and must additionally exercise a connected LiveView. P0.04 tests drag reordering with dispatched events or the required button path, without relying on a native drag helper in the selected Wallaby setup. Use branded Google Chrome for real Stream playback: Cloudflare's [player documentation](https://developers.cloudflare.com/stream/viewing-videos/using-the-stream-player/) warns about H.264 support in Chromium.

## PostgreSQL image and extension contract

Select a **combined image using prebuilt extension packages on the digest-pinned official PostgreSQL image**. This is the primary recipe for P0.06 ([#30](https://github.com/chenghanlee/tips/issues/30)); the source build below is a fallback if the packages fail on the target platform. Package availability, base digest and release checksum were verified in the [whole-PR review](https://github.com/chenghanlee/tips/pull/140#issuecomment-5751936068); this is not a built or SQL-verified Tips image.

| Input | Exact package or source pin | Status |
|---|---|---|
| PostgreSQL | `postgres:18.6-trixie@sha256:86c951e05bf56c93d95d397747fb8820ac76cc3bedb78f43abd83eedbe3666ae`; [official tag](https://hub.docker.com/layers/library/postgres/18.6-trixie/images) | Base manifest pinned; the official image includes the PGDG apt repository. Combined image remains unbuilt |
| pgvector | PGDG trixie amd64 `postgresql-18-pgvector=0.8.6-1.pgdg13+1`; [package index](https://apt.postgresql.org/pub/repos/apt/dists/trixie-pgdg/main/binary-amd64/Packages) | Exact package version selected; P0.06 verifies installation and extversion 0.8.6 |
| pg_textsearch | [pg-textsearch-v1.4.0-pg18-amd64.zip](https://github.com/timescale/pg_textsearch/releases/download/v1.4.0/pg-textsearch-v1.4.0-pg18-amd64.zip), SHA-256 `c2ce0585a7f09ec7fc441f1fba11888d6ad3ab51b1851d4f24a7457905d0519f`, containing `pg-textsearch-postgresql-18_1.4.0-1_amd64.deb` | Release asset pinned; P0.06 verifies installation and extversion 1.4.0 |

P0.06 starts its Dockerfile with:

```dockerfile
FROM postgres:18.6-trixie@sha256:86c951e05bf56c93d95d397747fb8820ac76cc3bedb78f43abd83eedbe3666ae
```

For linux/amd64, install `postgresql-18-pgvector=0.8.6-1.pgdg13+1` with `apt-get` from the image’s PGDG repository. Download the pinned pg_textsearch zip, verify its SHA-256 before extracting, then install `pg-textsearch-postgresql-18_1.4.0-1_amd64.deb` with `dpkg -i`. Set `shared_preload_libraries` as below. This path needs download/unzip tools but no compiler, server development headers or multi-stage source build. Confirm package installation preserves PostgreSQL 18.6. These are instructions, not commands executed in this task.

For native arm64 development, the same release publishes [pg-textsearch-v1.4.0-pg18-arm64.zip](https://github.com/timescale/pg_textsearch/releases/download/v1.4.0/pg-textsearch-v1.4.0-pg18-arm64.zip), with API-reported SHA-256 `f65bc4f46393ca66c78e4da71ae8c54d0aef9975eaf3d5b6836d0f4570c68c64`. The [PGDG trixie arm64 index](https://apt.postgresql.org/pub/repos/apt/dists/trixie-pgdg/main/binary-arm64/Packages) also carries `postgresql-18-pgvector=0.8.6-1.pgdg13+1`, as [Opus independently verified](https://github.com/chenghanlee/tips/pull/140#issuecomment-5751991242). P0.06 must verify the downloaded archive, installation and `extversion` on arm64; package availability is settled. Do not install amd64 debs in an arm64 image. The trust inputs are PGDG’s signed package metadata and the checksummed Timescale release asset. P0.06 records the resolved package checksums/snapshot and the final combined-image digest.

**Source fallback only:** pg_textsearch [v1.4.0](https://github.com/timescale/pg_textsearch/tree/v1.4.0), commit `7a932505b537d50ad8d2d068a053cd1dd7b646ea`, and pgvector [v0.8.6](https://github.com/pgvector/pgvector/tree/v0.8.6), commit `8ee86c96f0fd72390f890aa8a336fda6d3ab4c6c`. Build against the image’s PostgreSQL 18 `pg_config` and server development headers (`postgresql-server-dev-18`), with Git, CA certificates, a C compiler, GNU make and any LLVM/Clang tools required by that PGXS configuration. Run `make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config` then `make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config install` in each pinned checkout; for pgvector pass `OPTFLAGS=""` to avoid targeting only the builder’s CPU. Match the server patch version and architecture in build and runtime stages and retain runtime libraries required by the extensions. This fallback is also unexecuted.

The [pg_textsearch 1.4.0 instructions](https://github.com/timescale/pg_textsearch/blob/v1.4.0/README.md#installation) require `shared_preload_libraries = 'pg_textsearch'` and a restart before `CREATE EXTENSION pg_textsearch`. Install pgvector with `CREATE EXTENSION vector`; its SQL extension name differs from its repository name. PG18's official container uses the versioned data directory and a volume at `/var/lib/postgresql`; do not inherit the old PG17 volume layout blindly.

P0.06 must build/run the image, record immutable base/final digests and package inputs, verify both `pg_extension.extversion` values, and execute the actual [hybrid SQL](../design/technical/data-model.md#search). Required risks to resolve: 1024-dimension HNSW/iterative scans; BM25 syntax, punctuation and zero-match behavior under index and sequential plans; visibility/filters and bounded ranking/pagination; keyword fallback and the two-second query timeout; migration/restart, backup/restore and extension persistence; memory/latency on the intended architecture. The local server has neither extension. Docker was not started and no container/image build or extension SQL was run. P0.06 must not silently replace hybrid search with keyword-only search.

### P0.06 image implementation and evidence

[PR #144](https://github.com/chenghanlee/tips/pull/144) implements the package
recipe in [db/Dockerfile](../../db/Dockerfile). [Compose](../../compose.yaml),
[the smoke script](../../scripts/db_smoke.sh) and
[CI](../../.github/workflows/db-image.yml) select
`ghcr.io/chenghanlee/tips-postgres:18.6-pgvector0.8.6-textsearch1.4.0` and build the
same digest-pinned recipe natively. The image command preloads pg_textsearch on
every start, including existing volumes. Compose uses local-only credentials
`postgres`/`postgres`, binds `127.0.0.1:5433`, and mounts `/var/lib/postgresql`.
The smoke container publishes no port and removes its anonymous volume on exit.

On 2026-09-21, the native linux/arm64 build verified the release zip against the
previously API-reported SHA-256 above. PGDG's signed metadata selected the exact
pgvector package. The build prints both downloaded package checksums and stops
if installation changes PostgreSQL's version. It uses the PGDG archive only if
the exact pgvector version disappears from the live index, restricts that source
to pgvector, and fails rather than changing versions or building from source.

| Downloaded arm64 package | SHA-256 |
|---|---|
| `postgresql-18-pgvector_0.8.6-1.pgdg13+1_arm64.deb` | `e22d18cba71b5ae656a5f4b458cb59951866ef835e69e5ad1385777c91b1126b` |
| `pg-textsearch-postgresql-18_1.4.0-1_arm64.deb` | `d4bb42c1a6b7e3d0169399fe37285a44ab6e5170cc95dc6dabadf857ddeca9bf` |

`scripts/db_smoke.sh` passed locally on arm64: PostgreSQL 18.6, extension versions
0.8.6 and 1.4.0, two negative-score BM25 matches, cosine neighbors `{1,2}` with
1024 dimensions and relaxed iterative scanning, zero absent-token matches, and
EXPLAIN ANALYZE plans naming both `smoke_bm25` and `smoke_hnsw`. Before the image
existed, the same SQL failed on the pinned base with `extension "vector" is not
available` (psql exit 3). The fixture is a regular table in a disposable database;
it does not create the Tips search schema or certify the broader search risks
listed above.

The native amd64 PR workflow runs the same smoke before publication. On a
matching push to main it pushes the verified image with the repository's
`GITHUB_TOKEN` and `packages: write`; no personal push credential is needed. The
OCI source label links the package to this repository. The first GHCR package
is private by default; Fable-Tech-Lead must confirm visibility and authenticated
pull after merge, copy the pushed manifest digest from the run log to #30 and
append it here. The published image is amd64 only; local arm64 development builds
from the same recipe. No multi-architecture manifest is published by this task.

**Publication evidence pending merge:** no GHCR manifest digest or private pull
is claimed yet. The local arm64 image ID is
`sha256:f21588a97313d462cddffe037c523c0767357618b22757938b8ce97798c48073`;
this is an image configuration digest, not a registry manifest digest. Deployment
must select the published `ghcr.io/chenghanlee/tips-postgres@sha256:…` digest once
recorded. VPS credentials and its authenticated pull are owned by P13a; use a
registry credential with package read access on that host and pass it through
`docker login --password-stdin`, never store it in Compose or this repository.

Native linux/amd64 verification also passed on the
[PR workflow run](https://github.com/chenghanlee/tips/actions/runs/35534482017)
for commit `83957b8ad25da14464433b5f9bc5681818115d75`. The same extension versions,
query assertions and both index plans passed; publication was correctly skipped
on the PR event. The build verified the pinned amd64 ZIP checksum and logged:

| Downloaded amd64 package | SHA-256 |
|---|---|
| `postgresql-18-pgvector_0.8.6-1.pgdg13+1_amd64.deb` | `89402614430b2a7e06345f0f69b441bb7ee93913a14729f10c421f40b06d9d95` |
| `pg-textsearch-postgresql-18_1.4.0-1_amd64.deb` | `7fffdca1327b63245e72eec1d04fc1e45c73e447006131670eb721ab3bc08307` |

Local Compose was also verified with a fresh named volume: both extensions
created through host port 5433, survived restart with pg_textsearch preloaded,
and coexisted with a successful smoke run. The scoped test volume was removed.
An injected SQL exception made the smoke script exit 3 and remove its disposable
container and volume; the unmodified fixture was restored before commit.

Review follow-up (P2-3/P2-4): the PGDG archive fallback has not been executed;
all recorded builds resolved pgvector from the live signed index. The final
image now purges curl/unzip and their unused dependencies in the install layer;
CA certificates remain. Native arm64 smoke passed again after that cleanup,
and neither executable is present. Its updated local image configuration ID is
`sha256:3409e546c7c1646ad211b30cba66070ce2d5c03fde8edcd1432f5dbc854516cd`.
Registry publication and its manifest digest still await the main-branch run.

## Markdown, embeds and secure headers

Render tip/review authored Markdown through **MDEx 0.13.5 with its built-in Ammonia sanitizer** (`mdex_native`). Use one options list, without HtmlSanitizeEx or a custom Scrubber module:

```elixir
render: [unsafe: false],
sanitize: [
  tags: ~w(p br hr h1 h2 h3 h4 h5 h6 blockquote ul ol li pre code em strong del a table thead tbody tr th td),
  tag_attributes: %{"a" => ~w(href title)},
  generic_attributes: [],
  url_schemes: ~w(http https mailto),
  link_rel: "nofollow noopener noreferrer"
]
```

`unsafe: false` omits author raw HTML, but Markdown image syntax still produces an `img` tag. The sanitizer’s tag allowlist removes those images. Only the sanitized result may be marked HTML-safe. See [MDEx safety options](https://github.com/leandrocp/mdex/blob/v0.13.5/guides/safety.md). Titles and metadata stay escaped text; prompt/result fields stay verbatim escaped text with copy preserving bytes.

Fable-Tech-Lead’s [local MDEx 0.13.5 probe](https://github.com/chenghanlee/tips/pull/140#issuecomment-5751936068) used this exact policy with raw HTML, Markdown images, javascript/HTTPS/relative/mailto links and a fenced Elixir code block. It omitted raw HTML, removed the image, emptied the javascript href, retained link titles and relative/mailto URLs, added the specified `rel`, and stripped `class="language-elixir"`. This is focused policy evidence from the reviewer, not the generated application suite or a complete rendering-security test. Ammonia uses html5ever inside the renderer’s existing native dependency. Opus independently ran the policy on darwin-arm64; `mdex_native` prebuilt NIF availability on other target platforms remains to be proved. When adding MDEx, commit its resolved transitive dependencies in the application lock, including `mdex_native`, `lumis`, `nimble_parsec`, `jason` and the non-optional LiveView dependency; they are not additions to the captured generator baseline.

Allowed output tags: `p`, `br`, `hr`, `h1`–`h6`, `blockquote`, `ul`, `ol`, `li`, `pre`, `code`, `em`, `strong`, `del`, `a`, `table`, `thead`, `tbody`, `tr`, `th`, `td`. Allow only validated `href` and `title` on links; URI schemes are HTTPS/HTTP/mailto plus relative URLs/fragments. Add application-controlled `rel="nofollow noopener noreferrer"`; do not accept author `target`, styles, event handlers, scripts, forms, SVG, images, video or iframe tags. Uploaded media is rendered separately through authorized components. Disable syntax highlighting initially so the allowlist needs no author-controlled style/class exceptions. The implementation task must test malformed HTML, encoded/script/data URLs, raw HTML omission and normal Markdown; this policy is not evidence that those fixtures already pass.

**Author embed host allowlist: empty.** No pasted iframe or automatic third-party URL embed. Required application-owned embeds are separate HEEx components:

- Turnstile script/frame: exactly `https://challenges.cloudflare.com`.
- Private Stream player: exactly the configured `https://customer-<CODE>.cloudflarestream.com` host (the code is owner/provider configuration still to be supplied). The initial iframe source is the same-origin `/media/{id}/watch` route, which authorizes then redirects to the signed `/iframe` destination. Do not wildcard all customer hosts or accept an author-supplied destination. Thumbnails use the separately authorized route; R2 images use the configured cookie-free media origin.

Retain the generated `put_secure_browser_headers` plug and all [Phoenix 1.8.14 defaults](https://github.com/phoenixframework/phoenix/blob/v1.8.14/lib/phoenix/controller.ex): CSP `base-uri 'self'; frame-ancestors 'self';`, `referrer-policy: strict-origin-when-cross-origin`, `x-content-type-options: nosniff`, and `x-permitted-cross-domain-policies: none`. Those defaults restrict who can frame Tips; they do not forbid Tips from embedding Stream or Turnstile. Inspection of the pinned source confirms no default `frame-src`/`script-src` restriction conflicts with them.

When adding a stricter CSP, preserve those default directives and allow `frame-src 'self' https://challenges.cloudflare.com https://customer-<CODE>.cloudflarestream.com`, plus Turnstile's exact script host or its documented nonce approach. Follow [Turnstile's CSP requirements](https://developers.cloudflare.com/turnstile/reference/content-security-policy/). Test the real redirects, signed video playback and signup widget during the authorized provider gate; no account, real customer host, signing key or browser/provider compatibility proof was available here. Do not weaken global headers to accommodate authored HTML.

## Acceptance map

| Scenario | Evidence / remaining gate |
|---|---|
| 1. Exact versions and primary sources | Runtime and application tables; each unproven input marked open-risk |
| 2. Disposable generator, compiler and suite | Commands above: generator 0, final dependency fetch 0, compiler 0, suite 0 / five passing tests; initial cache failures retained |
| 3. Browser driver, dependencies, matrix, smoke | Wallaby/Chrome decision and runnable standalone smoke; execution owned by P0.04 ([#36](https://github.com/chenghanlee/tips/issues/36)) |
| 4. PG18 image containing both extensions | Combined-build inputs and explicit P0.06 digest/build/SQL obligations |
| 5. Markdown, sanitizer, hosts and headers | Explicit MDEx sanitizer policy, empty author embed allowlist, application provider hosts and retained Phoenix defaults |

## Captured generator lock

This is the baseline lock before adding any optional candidates. SHA-256: `c74b88d3dc7cef01db79b53ac821e97c320f1bf91ebb8d0696e2f7a2a6b54a27`. To reproduce, copy this block verbatim into the disposable application's `mix.lock` before fetching dependencies. P0.02 must commit its real application lock when it adopts these pins.

<details>
<summary>mix.lock (complete)</summary>

```elixir
%{
  "bandit": {:hex, :bandit, "1.12.5", "af205a8e550f304caae09a97d29fd3c79a7f337526ea7cd772d2ff11d2f7c800", [:mix], [{:hpax, "~> 1.0", [hex: :hpax, repo: "hexpm", optional: false]}, {:plug, "~> 1.18", [hex: :plug, repo: "hexpm", optional: false]}, {:telemetry, "~> 0.4 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}, {:thousand_island, "~> 1.5", [hex: :thousand_island, repo: "hexpm", optional: false]}, {:websock, "~> 0.5", [hex: :websock, repo: "hexpm", optional: false]}], "hexpm", "c5684ca062fa407cac115aec3256383f3e2ec9fdced7904d59cf5a7bb7ed6181"},
  "cc_precompiler": {:hex, :cc_precompiler, "0.1.11", "8c844d0b9fb98a3edea067f94f616b3f6b29b959b6b3bf25fee94ffe34364768", [:mix], [{:elixir_make, "~> 0.7", [hex: :elixir_make, repo: "hexpm", optional: false]}], "hexpm", "3427232caf0835f94680e5bcf082408a70b48ad68a5f5c0b02a3bea9f3a075b9"},
  "daisyui": {:git, "https://github.com/saadeghi/daisyui.git", "22ecff57f2c391b80a75617325748cf4d13fdf47", [tag: "v5.5.20", sparse: "packages/bundle", depth: 1]},
  "db_connection": {:hex, :db_connection, "2.10.2", "ae391e803a5adff104da913c2fc1c0c14a37f8b10001dcef568796e1fb7bf95c", [:mix], [{:telemetry, "~> 0.4 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "510b14482330f1af6490a2fa0efd8d4f1435d1529b165647df22ac0f2df0fa93"},
  "decimal": {:hex, :decimal, "3.1.1", "430d87b04011ce6cbd4fd205be758311a81f87d552d40904abd00f015935b1d0", [:mix], [], "hexpm", "c5f25f2ced74a0587d03e6023f595db8e924c9d3922c8c8ffd9edfc4498cf1f6"},
  "dns_cluster": {:hex, :dns_cluster, "0.2.0", "aa8eb46e3bd0326bd67b84790c561733b25c5ba2fe3c7e36f28e88f384ebcb33", [:mix], [], "hexpm", "ba6f1893411c69c01b9e8e8f772062535a4cf70f3f35bcc964a324078d8c8240"},
  "ecto": {:hex, :ecto, "3.14.2", "99db28a864293a789c970651de711e3cae184291e0e7ea1166c54055ac41c1f3", [:mix], [{:decimal, "~> 3.0", [hex: :decimal, repo: "hexpm", optional: false]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: true]}, {:telemetry, "~> 0.4 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "25d60b8c816a07d19d85b80bdf60978bd8b102209dda198d768cd7c6745339a6"},
  "ecto_sql": {:hex, :ecto_sql, "3.14.0", "06446ab8410d2f85bfbb80857ee224ab3b693700cbb38f6535d507449a627b2e", [:mix], [{:db_connection, "~> 2.9", [hex: :db_connection, repo: "hexpm", optional: false]}, {:decimal, "~> 3.0", [hex: :decimal, repo: "hexpm", optional: false]}, {:ecto, "~> 3.14.0", [hex: :ecto, repo: "hexpm", optional: false]}, {:myxql, "~> 0.8", [hex: :myxql, repo: "hexpm", optional: true]}, {:postgrex, "~> 0.19 or ~> 1.0", [hex: :postgrex, repo: "hexpm", optional: true]}, {:tds, "~> 2.1.1 or ~> 2.2", [hex: :tds, repo: "hexpm", optional: true]}, {:telemetry, "~> 0.4.0 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "f4d8d36faf294c9417b5a37ec7ac8217ee2abdef5fcf197ba690f361548d3949"},
  "elixir_make": {:hex, :elixir_make, "0.10.0", "16577e2583a79bb79237bbff349619ef5d80afffc07eac6e4faf0d00e2ddaf7d", [:mix], [], "hexpm", "dc1f09fb7fa68866b886abd5f0f3c83553b1a19a52359a899e92af1bb3b31982"},
  "esbuild": {:hex, :esbuild, "0.10.0", "b0aa3388a1c23e727c5a3e7427c932d89ee791746b0081bbe56103e9ef3d291f", [:mix], [{:jason, "~> 1.4", [hex: :jason, repo: "hexpm", optional: false]}], "hexpm", "468489cda427b974a7cc9f03ace55368a83e1a7be12fba7e30969af78e5f8c70"},
  "expo": {:hex, :expo, "1.1.1", "4202e1d2ca6e2b3b63e02f69cfe0a404f77702b041d02b58597c00992b601db5", [:mix], [], "hexpm", "5fb308b9cb359ae200b7e23d37c76978673aa1b06e2b3075d814ce12c5811640"},
  "file_system": {:hex, :file_system, "1.1.1", "31864f4685b0148f25bd3fbef2b1228457c0c89024ad67f7a81a3ffbc0bbad3a", [:mix], [], "hexpm", "7a15ff97dfe526aeefb090a7a9d3d03aa907e100e262a0f8f7746b78f8f87a5d"},
  "finch": {:hex, :finch, "0.23.0", "e3f9287ac25a8832f848b144c2b57346aac65b205e2e0629a52adfe6507fd837", [:mix], [{:mime, "~> 1.0 or ~> 2.0", [hex: :mime, repo: "hexpm", optional: false]}, {:mint, "~> 1.8", [hex: :mint, repo: "hexpm", optional: false]}, {:nimble_options, "~> 0.4 or ~> 1.0", [hex: :nimble_options, repo: "hexpm", optional: false]}, {:nimble_pool, "~> 1.1", [hex: :nimble_pool, repo: "hexpm", optional: false]}, {:telemetry, "~> 0.4 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "80e58d3f936f57e3fdf404f83a3642897ae6d9fb642934e46da4d8fe761b99d5"},
  "fine": {:hex, :fine, "0.1.6", "4bf7151493443c454aac9f2fa2f34f5fefd0346a83fb5586a016c4a135c63247", [:mix], [], "hexpm", "5638eb4495488e885ebec167fa57973e5c35e1a50c344eb7666c90ec1c4e3b12"},
  "gettext": {:hex, :gettext, "1.0.2", "5457e1fd3f4abe47b0e13ff85086aabae760497a3497909b8473e0acee57673b", [:mix], [{:expo, "~> 0.5.1 or ~> 1.0", [hex: :expo, repo: "hexpm", optional: false]}], "hexpm", "eab805501886802071ad290714515c8c4a17196ea76e5afc9d06ca85fb1bfeb3"},
  "heroicons": {:git, "https://github.com/tailwindlabs/heroicons.git", "0435d4ca364a608cc75e2f8683d374e55abbae26", [tag: "v2.2.0", sparse: "optimized", depth: 1]},
  "hpax": {:hex, :hpax, "1.0.4", "777de5d433b0fbdc7c418159c8055910faa8047ffdb3d6b31098d2a46cd7685c", [:mix], [], "hexpm", "afc7cb142ebcc2d01ce7816190b98ce5dd49e799111b24249f3443d730f377ca"},
  "idna": {:hex, :idna, "7.1.0", "1067a13043538129602d2f2ce6899d8713125c7d19734aa557ce2e3ea55bd4f1", [:rebar3], [], "hexpm", "6ae959a025bf36df61a8cab8508d9654891b5426a84c44d82deaffd6ddf8c71f"},
  "jason": {:hex, :jason, "1.4.5", "2e3a008590b0b8d7388c20293e9dcc9cf3e5d642fd2a114e4cbbb52e595d940a", [:mix], [{:decimal, "~> 1.0 or ~> 2.0 or ~> 3.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"},
  "lazy_html": {:hex, :lazy_html, "0.1.12", "31a55ee622918fce988c94b06232227b42daa64e4eab14ac32081d0f3fd8db6f", [:make, :mix], [{:cc_precompiler, "~> 0.1", [hex: :cc_precompiler, repo: "hexpm", optional: false]}, {:elixir_make, "~> 0.9", [hex: :elixir_make, repo: "hexpm", optional: false]}, {:fine, "~> 0.1.0", [hex: :fine, repo: "hexpm", optional: false]}], "hexpm", "8a0da594776caee58782c6f93b2abaa5bdb809daf8d43351a561f7de9dc2e2a8"},
  "mime": {:hex, :mime, "2.0.7", "b8d739037be7cd402aee1ba0306edfdef982687ee7e9859bee6198c1e7e2f128", [:mix], [], "hexpm", "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd"},
  "mint": {:hex, :mint, "1.10.1", "c53e70867cf74017716884d8d33e0742b08b32e9cdb0031cbc69a429dc5555e3", [:mix], [{:castore, "~> 0.1.0 or ~> 1.0", [hex: :castore, repo: "hexpm", optional: true]}, {:hpax, "~> 0.1.1 or ~> 0.2.0 or ~> 1.0", [hex: :hpax, repo: "hexpm", optional: false]}], "hexpm", "0ba2a904605ed8406393444fb8b3356dc58eb59ee6c7fb94ac3f015e1be129e8"},
  "nimble_options": {:hex, :nimble_options, "1.1.1", "e3a492d54d85fc3fd7c5baf411d9d2852922f66e69476317787a7b2bb000a61b", [:mix], [], "hexpm", "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44"},
  "nimble_pool": {:hex, :nimble_pool, "1.1.0", "bf9c29fbdcba3564a8b800d1eeb5a3c58f36e1e11d7b7fb2e084a643f645f06b", [:mix], [], "hexpm", "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a"},
  "phoenix": {:hex, :phoenix, "1.8.14", "9279cbbcd755ac8d5f42d206915e7df13b9ab49096b98114f1c99ff908e5b42e", [:mix], [{:bandit, "~> 1.0", [hex: :bandit, repo: "hexpm", optional: true]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: true]}, {:phoenix_pubsub, "~> 2.1", [hex: :phoenix_pubsub, repo: "hexpm", optional: false]}, {:phoenix_template, "~> 1.0", [hex: :phoenix_template, repo: "hexpm", optional: false]}, {:phoenix_view, "~> 2.0", [hex: :phoenix_view, repo: "hexpm", optional: true]}, {:plug, "~> 1.14", [hex: :plug, repo: "hexpm", optional: false]}, {:plug_cowboy, "~> 2.7", [hex: :plug_cowboy, repo: "hexpm", optional: true]}, {:plug_crypto, "~> 2.2", [hex: :plug_crypto, repo: "hexpm", optional: false]}, {:telemetry, "~> 0.4 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}, {:websock_adapter, "~> 0.5", [hex: :websock_adapter, repo: "hexpm", optional: false]}], "hexpm", "2782ff375824b2b5e41561fbae4764ee7b875af6898483bca49f24a9d1e37816"},
  "phoenix_ecto": {:hex, :phoenix_ecto, "4.7.0", "75c4b9dfb3efdc42aec2bd5f8bccd978aca0651dbcbc7a3f362ea5d9d43153c6", [:mix], [{:ecto, "~> 3.5", [hex: :ecto, repo: "hexpm", optional: false]}, {:phoenix_html, "~> 2.14.2 or ~> 3.0 or ~> 4.1", [hex: :phoenix_html, repo: "hexpm", optional: true]}, {:plug, "~> 1.9", [hex: :plug, repo: "hexpm", optional: false]}, {:postgrex, "~> 0.16 or ~> 1.0", [hex: :postgrex, repo: "hexpm", optional: true]}], "hexpm", "1d75011e4254cb4ddf823e81823a9629559a1be93b4321a6a5f11a5306fbf4cc"},
  "phoenix_html": {:hex, :phoenix_html, "4.3.0", "d3577a5df4b6954cd7890c84d955c470b5310bb49647f0a114a6eeecc850f7ad", [:mix], [], "hexpm", "3eaa290a78bab0f075f791a46a981bbe769d94bc776869f4f3063a14f30497ad"},
  "phoenix_live_dashboard": {:hex, :phoenix_live_dashboard, "0.8.7", "405880012cb4b706f26dd1c6349125bfc903fb9e44d1ea668adaf4e04d4884b7", [:mix], [{:ecto, "~> 3.6.2 or ~> 3.7", [hex: :ecto, repo: "hexpm", optional: true]}, {:ecto_mysql_extras, "~> 0.5", [hex: :ecto_mysql_extras, repo: "hexpm", optional: true]}, {:ecto_psql_extras, "~> 0.7", [hex: :ecto_psql_extras, repo: "hexpm", optional: true]}, {:ecto_sqlite3_extras, "~> 1.1.7 or ~> 1.2.0", [hex: :ecto_sqlite3_extras, repo: "hexpm", optional: true]}, {:mime, "~> 1.6 or ~> 2.0", [hex: :mime, repo: "hexpm", optional: false]}, {:phoenix_live_view, "~> 0.19 or ~> 1.0", [hex: :phoenix_live_view, repo: "hexpm", optional: false]}, {:telemetry_metrics, "~> 0.6 or ~> 1.0", [hex: :telemetry_metrics, repo: "hexpm", optional: false]}], "hexpm", "3a8625cab39ec261d48a13b7468dc619c0ede099601b084e343968309bd4d7d7"},
  "phoenix_live_reload": {:hex, :phoenix_live_reload, "1.7.0", "fb1e429f6d8778ce3a6962debdc5e555428a05a6e7b058d6dbad13d281a2c31f", [:mix], [{:file_system, "~> 0.2.10 or ~> 1.0", [hex: :file_system, repo: "hexpm", optional: false]}, {:phoenix, "~> 1.4", [hex: :phoenix, repo: "hexpm", optional: false]}], "hexpm", "dc9f44271aa6fc4ab7797f2aa374ba096ef2c87520586280eb095626b7387a68"},
  "phoenix_live_view": {:hex, :phoenix_live_view, "1.2.12", "35848150bbab579e9d0aff79525269d7c0801a4f61232b84f635c11222cee88f", [:mix], [{:igniter, ">= 0.6.16 and < 1.0.0-0", [hex: :igniter, repo: "hexpm", optional: true]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: true]}, {:lazy_html, "~> 0.1.0", [hex: :lazy_html, repo: "hexpm", optional: true]}, {:phoenix, "~> 1.6.15 or ~> 1.7.0 or ~> 1.8.0", [hex: :phoenix, repo: "hexpm", optional: false]}, {:phoenix_html, "~> 3.3 or ~> 4.0", [hex: :phoenix_html, repo: "hexpm", optional: false]}, {:phoenix_template, "~> 1.0", [hex: :phoenix_template, repo: "hexpm", optional: false]}, {:phoenix_view, "~> 2.0", [hex: :phoenix_view, repo: "hexpm", optional: true]}, {:plug, "~> 1.15", [hex: :plug, repo: "hexpm", optional: false]}, {:telemetry, "~> 0.4.2 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "656810d716e3369545dd63981196a5d68b77fdb253afe02ef0c6fa14cfd8dc2b"},
  "phoenix_pubsub": {:hex, :phoenix_pubsub, "2.3.0", "03916bfbc31a5121945b3cfffe5aec647a5c97fe1dc172a319b94428562359c9", [:mix], [], "hexpm", "eec7be6e9cf02e2551d389b558402d6c637cd3973796326e7ba4bb03c6b2e91d"},
  "phoenix_template": {:hex, :phoenix_template, "1.0.4", "e2092c132f3b5e5b2d49c96695342eb36d0ed514c5b252a77048d5969330d639", [:mix], [{:phoenix_html, "~> 2.14.2 or ~> 3.0 or ~> 4.0", [hex: :phoenix_html, repo: "hexpm", optional: true]}], "hexpm", "2c0c81f0e5c6753faf5cca2f229c9709919aba34fab866d3bc05060c9c444206"},
  "plug": {:hex, :plug, "1.20.3", "56c480c633ec2ce10140e236e15233bf576e1d323887d7c96711bd02ab5160db", [:mix], [{:mime, "~> 1.0 or ~> 2.0", [hex: :mime, repo: "hexpm", optional: false]}, {:plug_crypto, "~> 1.1.1 or ~> 1.2 or ~> 2.0", [hex: :plug_crypto, repo: "hexpm", optional: false]}, {:telemetry, "~> 0.4.3 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "be266aee1b8536ef6409d58cf39a3121319f0ec47cfa1b24024485aa0e76ad76"},
  "plug_crypto": {:hex, :plug_crypto, "2.2.0", "144014737daaf485407f5ed77daeaad74d651b216a28c87543f8cc7043f8efc8", [:mix], [], "hexpm", "83a95744ab1c75876542b6fab135fcc176280e0f301a111c1f757fddcec95d2c"},
  "postgrex": {:hex, :postgrex, "0.22.4", "d271f595dfd25230b6398354e19d17bb5e2d20130fd2d9bdca7e15f125d43552", [:mix], [{:db_connection, "~> 2.9", [hex: :db_connection, repo: "hexpm", optional: false]}, {:decimal, "~> 1.5 or ~> 2.0 or ~> 3.0", [hex: :decimal, repo: "hexpm", optional: false]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: true]}, {:table, "~> 0.1.0", [hex: :table, repo: "hexpm", optional: true]}], "hexpm", "4aae45a2d60e35b04eea2602440be152fae332901f1fc7a60fc7cb7f0f9a9c5a"},
  "req": {:hex, :req, "0.7.4", "23e9ffec17de032a46a4b15ed65c09793893bf4a7c680f4bbf6227fce6bdf74d", [:mix], [{:brotli, "~> 0.3.1", [hex: :brotli, repo: "hexpm", optional: true]}, {:finch, "~> 0.21", [hex: :finch, repo: "hexpm", optional: false]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: false]}, {:mime, "~> 2.0.6 or ~> 2.1", [hex: :mime, repo: "hexpm", optional: false]}, {:nimble_csv, "~> 1.0", [hex: :nimble_csv, repo: "hexpm", optional: true]}, {:plug, "~> 1.0", [hex: :plug, repo: "hexpm", optional: true]}], "hexpm", "4b192d63253e8dcc6221ef992ea9ebef7d3555166e8423aa5b553e86bc3c69a2"},
  "swoosh": {:hex, :swoosh, "1.28.1", "1a836e6a938a93bd2dbd99734267bda876894473e76b510ece20e5681510ceb1", [:mix], [{:bandit, ">= 1.0.0", [hex: :bandit, repo: "hexpm", optional: true]}, {:cowboy, "~> 1.1 or ~> 2.4", [hex: :cowboy, repo: "hexpm", optional: true]}, {:ex_aws, "~> 2.1", [hex: :ex_aws, repo: "hexpm", optional: true]}, {:finch, "~> 0.6", [hex: :finch, repo: "hexpm", optional: true]}, {:gen_smtp, "~> 0.13 or ~> 1.0", [hex: :gen_smtp, repo: "hexpm", optional: true]}, {:hackney, ">= 1.9.0 and < 5.0.0", [hex: :hackney, repo: "hexpm", optional: true]}, {:idna, ">= 6.0.0 and < 8.0.0", [hex: :idna, repo: "hexpm", optional: false]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: false]}, {:mail, "~> 0.2", [hex: :mail, repo: "hexpm", optional: true]}, {:mime, "~> 1.1 or ~> 2.0", [hex: :mime, repo: "hexpm", optional: false]}, {:mua, "~> 0.2.3", [hex: :mua, repo: "hexpm", optional: true]}, {:multipart, "~> 0.4", [hex: :multipart, repo: "hexpm", optional: true]}, {:plug, "~> 1.9", [hex: :plug, repo: "hexpm", optional: true]}, {:plug_cowboy, ">= 1.0.0", [hex: :plug_cowboy, repo: "hexpm", optional: true]}, {:req, "~> 0.5.10 or ~> 0.6 or ~> 1.0", [hex: :req, repo: "hexpm", optional: true]}, {:telemetry, "~> 0.4.2 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "d84e08c445f70617afd3a31633db2ea02ceabdfec482bde4b824da63b8150bdc"},
  "tailwind": {:hex, :tailwind, "0.5.1", "35435b13158c90d37da11e1cfc808755fca1d7b6c5ab87b1b19c5de87e2f0a10", [:mix], [], "hexpm", "c4e26302a59fec72abc5610ecb6ad2116d9aa31f31aab2d4b8eb6e95d25a689c"},
  "telemetry": {:hex, :telemetry, "1.4.2", "a0cb522801dffb1c49fe6e30561badffc7b6d0e180db1300df759faa22062855", [:rebar3], [], "hexpm", "928f6495066506077862c0d1646609eed891a4326bee3126ba54b60af61febb1"},
  "telemetry_metrics": {:hex, :telemetry_metrics, "1.2.0", "7632c19c01d88d8aaca5da1a0e8912f5af39b79e7c08a2c253aeb3c14c2c957e", [:mix], [{:telemetry, "~> 0.4 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "71dde12fc29b58b9c77ec17ec319109e5ca848d010fc1965ed4463bba1837c07"},
  "telemetry_poller": {:hex, :telemetry_poller, "1.3.0", "d5c46420126b5ac2d72bc6580fb4f537d35e851cc0f8dbd571acf6d6e10f5ec7", [:rebar3], [{:telemetry, "~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "51f18bed7128544a50f75897db9974436ea9bfba560420b646af27a9a9b35211"},
  "thousand_island": {:hex, :thousand_island, "1.5.0", "f50a213cac97262b6d5ebb85745aa2c00fec1413191e6e66834788d45425cecb", [:mix], [{:telemetry, "~> 0.4 or ~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}], "hexpm", "708923d40523e43cf99041ab37a0d4b0ec426ac6438fa3716ab23d919eaeb412"},
  "websock": {:hex, :websock, "0.5.3", "2f69a6ebe810328555b6fe5c831a851f485e303a7c8ce6c5f675abeb20ebdadc", [:mix], [], "hexpm", "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453"},
  "websock_adapter": {:hex, :websock_adapter, "0.6.0", "73db5ab8aaefd1a876a97ce3e6afc96562625de69ef17a4e04426e034849d0b8", [:mix], [{:bandit, ">= 0.6.0", [hex: :bandit, repo: "hexpm", optional: true]}, {:plug, "~> 1.14", [hex: :plug, repo: "hexpm", optional: false]}, {:plug_cowboy, "~> 2.6", [hex: :plug_cowboy, repo: "hexpm", optional: true]}, {:websock, "~> 0.5", [hex: :websock, repo: "hexpm", optional: false]}], "hexpm", "50021a85bce8f203b086705d9e0c5415e2c7eb05d319111b0428fe71f9934617"},
}
```

</details>
