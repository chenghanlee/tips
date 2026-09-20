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

## Application dependencies

The matrix versions for generated dependencies come from the captured `mix.lock`, not the generator’s `~>` ranges. The committed lock enforces exact resolved versions, including transitive dependencies. “Pinned” means the selected version is exact; it does not mean all Tips behavior has passed. Use exact Mix requirements (for example `{:phoenix, "== 1.8.14"}`), commit the application's `mix.lock`, and pin downloaded asset binaries in config. Do not replace these with `latest`. The generated baseline's full lock is retained below so its transitive dependencies can be reproduced.

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
| UI candidate | [salad_ui 1.0.0](https://hex.pm/packages/salad_ui/1.0.0) | Open-risk candidate; published requirement is LiveView `~> 1.2`. P16.00 must prove hooks, errors, keyboard focus, patches and reconnect on this Tailwind/Phoenix combination |
| Markdown renderer | [mdex 0.13.5](https://hex.pm/packages/mdex/0.13.5) | Pinned, open integration risk; native binary/platform availability and rendering fixtures still need proof |
| HTML sanitizer | [html_sanitize_ex 1.5.5](https://hex.pm/packages/html_sanitize_ex/1.5.5) | Pinned, open integration risk; explicit final allowlist policy below |
| Browser driver | [wallaby 0.31.0](https://hex.pm/packages/wallaby/0.31.0) with `Wallaby.Chrome` | Pinned, open runtime risk until browser setup task executes the smoke below |

The generator does not install Oban, SaladUI, MDEx, HtmlSanitizeEx or Wallaby. Their presence in this decision table is not a claim that this run compiled or exercised them together. No version combination is certified for Tips until the owning P16.00/P0.06 probes and feature checks pass.

## Disposable generator evidence

Run on 2026-09-21 (Asia/Manila), macOS arm64, outside the repository at `/private/tmp/tips-22-probe.hv43AG/tips_probe`. Database namespace: `tips_22_probe_hv43ag_test`; no provider namespace or credentials were used. The test endpoint stayed disabled, so no HTTP port was bound. Local PostgreSQL listens on 5432.

The following are the exact substantive commands and their results. Output was captured under the parent probe directory. The generator intentionally retained HTML, LiveView, Ecto, mailer and assets; `--no-install` makes dependency resolution and its failures visible separately.

```sh
# cwd: /private/tmp; exit 0, returned /private/tmp/tips-22-probe.hv43AG
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

Expected exit 0. **Not executed here:** ChromeDriver is absent. This command proves driver startup and DOM access only; the application browser setup task must additionally exercise a connected LiveView. Use branded Google Chrome for real Stream playback: Cloudflare's [player documentation](https://developers.cloudflare.com/stream/viewing-videos/using-the-stream-player/) warns about H.264 support in Chromium.

## PostgreSQL image and extension contract

Select a **custom combined build based on `postgres:18.6-trixie`**, with the following source pins. This is an open-risk build specification, not a published or verified Tips image. The base manifest digest, apt package snapshot and resulting combined image digest remain P0.06 deliverables. No existing image is assumed to contain both exact extensions.

| Input | Exact source pin | Status |
|---|---|---|
| PostgreSQL | 18.6, Debian trixie variant; [official image build](https://github.com/docker-library/postgres/tree/master/18/trixie) | Open image/digest risk; only local Homebrew PG18.6 tested here |
| pg_textsearch | [v1.4.0](https://github.com/timescale/pg_textsearch/tree/v1.4.0), commit `7a932505b537d50ad8d2d068a053cd1dd7b646ea` | Pinned source, open PG18 combined-build and SQL risk |
| pgvector | [v0.8.6](https://github.com/pgvector/pgvector/tree/v0.8.6), commit `8ee86c96f0fd72390f890aa8a336fda6d3ab4c6c` | Pinned source, open PG18 combined-build and SQL risk |

Build both into the same image against its PostgreSQL 18 `pg_config` and server development headers (Debian package `postgresql-server-dev-18`), using Git, CA certificates, a C compiler and GNU make. Install any LLVM/Clang tools required by that PGXS configuration. The source-build core is `make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config` then `make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config install` in each pinned checkout; for pgvector pass `OPTFLAGS=""` to avoid producing a build tied to the builder's CPU. These are instructions for P0.06, **not commands executed in this task**. Match the server patch version and architecture in build and runtime stages and retain runtime libraries required by the compiled extensions.

The [pg_textsearch 1.4.0 instructions](https://github.com/timescale/pg_textsearch/blob/v1.4.0/README.md#installation) require `shared_preload_libraries = 'pg_textsearch'` and a restart before `CREATE EXTENSION pg_textsearch`. Install pgvector with `CREATE EXTENSION vector`; its SQL extension name differs from its repository name. PG18's official container uses the versioned data directory and a volume at `/var/lib/postgresql`; do not inherit the old PG17 volume layout blindly.

P0.06 must build/run the image, record immutable base/final digests and package inputs, verify both `pg_extension.extversion` values, and execute the actual [hybrid SQL](../design/technical/data-model.md#search). Required risks to resolve: 1024-dimension HNSW/iterative scans; BM25 syntax, punctuation and zero-match behavior under index and sequential plans; visibility/filters and bounded ranking/pagination; keyword fallback and the two-second query timeout; migration/restart, backup/restore and extension persistence; memory/latency on the intended architecture. The local server has neither extension. Docker was not started and no container/image build or extension SQL was run. P0.06 must not silently replace hybrid search with keyword-only search.

## Markdown, embeds and secure headers

Render only tip/review authored Markdown through **MDEx 0.13.5**, explicitly with `render: [unsafe: false]` so author raw HTML is omitted. Then sanitize generated HTML with **HtmlSanitizeEx 1.5.5**, using a Tips allowlist scrubber. See [MDEx safety options](https://github.com/leandrocp/mdex/blob/v0.13.5/guides/safety.md) and [HtmlSanitizeEx scrubbers](https://hexdocs.pm/html_sanitize_ex/1.5.5/HtmlSanitizeEx.Scrubber.html). Only the sanitized result may be marked HTML-safe. Titles and metadata stay escaped text; prompt/result fields stay verbatim escaped text with copy preserving bytes.

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
| 3. Browser driver, dependencies, matrix, smoke | Wallaby/Chrome decision and runnable standalone smoke; execution pending browser setup |
| 4. PG18 image containing both extensions | Combined-build inputs and explicit P0.06 digest/build/SQL obligations |
| 5. Markdown, sanitizer, hosts and headers | Explicit renderer/scrubber policy, empty author embed allowlist, application provider hosts and retained Phoenix defaults |

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
