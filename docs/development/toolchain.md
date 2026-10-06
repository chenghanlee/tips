# Toolchain

This guide identifies the build inputs and dependency rules for Tips.
For installation, commands and troubleshooting, use
[local development](local-development.md).

## Version sources

Read versions from the files that enforce them. Update those files together
when changing the toolchain.

| Input | Source |
|---|---|
| Elixir and Erlang/OTP | [CI runtime](../../.github/workflows/checks.yml) and [release builder](../../Dockerfile) |
| Hex and application build/runtime images | [Application Dockerfile](../../Dockerfile) |
| Phoenix and resolved application dependencies | [mix.lock](../../mix.lock) |
| Tailwind and esbuild binaries | [Asset configuration](../../config/config.exs) |
| PostgreSQL, extensions and archive checksums | [Database Dockerfile](../../db/Dockerfile) |
| Chrome for Testing and matching ChromeDriver | [CI browser setup](../../.github/workflows/checks.yml) |
| Agent clients, models and launch settings | [Pair configuration](../../agent/teams/config.toml) |
| Agent language-server builds | [LSP setup](../../agent/lsp/README.md) |

## Dependency updates

[mix.exs](../../mix.exs) declares dependency requirements;
[mix.lock](../../mix.lock) records exact resolved versions, including transitive
dependencies. CI runs `mix deps.get --check-locked`.

Use `mix deps.update` for reviewed upgrades and commit the updated lockfile.
Keep downloaded asset binaries and container base images pinned. Do not use
`latest`. Container image pins do not pin subsequent APT package updates.
Run the relevant application, browser or database checks after an upgrade.

## Library selections

These selections guide feature implementation. Check the lockfile to see what
is installed; selection alone does not establish compatibility.

| Library | Selection and integration requirements |
|---|---|
| Background jobs | [Oban 2.24.1](https://hex.pm/packages/oban/2.24.1), using the application's Ecto Repo and PostgreSQL |
| UI components | [SaladUI 1.0.0](https://hex.pm/packages/salad_ui/1.0.0) in library mode, [verified](https://github.com/chenghanlee/tips/issues/41) with Phoenix 1.8.14, LiveView 1.2.12, Tailwind 4.3.0 and esbuild 0.25.4; adds `tw_merge` 0.1.1, `igniter` 0.8.4 and `sourceror` 1.12.3. After `mix salad.setup`: delete its prepended bare `@import "tailwindcss";`, its `.dark` block and `@custom-variant dark`, the unused `salad_ui.css`, `tailwind.colors.json`, typography plugin and `tw-animate.css`, and revert its `app.js` patch (Tips uses no SaladUI JavaScript components); write the base border rule as `border-color: var(--border)`, gate `form_message` errors with `used_input?/1`, and call components by module to avoid `CoreComponents` name clashes. daisyUI is removed; `assets/css/app.css` holds the token values and [tokens.md](../design/visual/tokens.md) their rules. Native `<details>` needs `JS.ignore_attributes(["open"])` to stay open across patches |
| Markdown | [MDEx 0.13.5](https://hex.pm/packages/mdex/0.13.5); verify native dependency support on each target platform and the [rendering policy](../design/backend-design.md#markdown-embeds-and-secure-headers) |
| Image parser | [Pillow 12.3.0](https://pypi.org/project/pillow/12.3.0/) wheels pinned by hash, run as a child process under `timeout` and `prlimit`; see the [image parser probe](image-parser-probe.md#contract-for-62) |
| Browser tests | [Wallaby 0.31.0](https://hex.pm/packages/wallaby/0.31.0), with matching Chrome and ChromeDriver |

Retain Heroicons. Account for SaladUI's installer and
class-merging dependencies, and commit all resolved transitive dependencies.

## PostgreSQL image and extension contract

[db/Dockerfile](../../db/Dockerfile) builds the extension-enabled image from
prebuilt packages for amd64 and arm64. It checks the pg_textsearch archive
against a pinned SHA-256 per architecture; the pgvector package relies on APT
signature checks. It refuses a PostgreSQL version change. If the pinned pgvector
package leaves the live signed index, it uses the PGDG archive for that package
only. It does not switch versions or compile extensions from source.

The image preloads pg_textsearch on every start, including existing volumes.
The SQL extension names are `vector` and `pg_textsearch`; the data volume mounts
at `/var/lib/postgresql`. Follow the
[local database instructions](local-development.md#extension-enabled-database)
for Compose and smoke-test commands.

[Database CI](../../.github/workflows/db-image.yml) builds and smokes native
amd64, then publishes matching main-branch builds to GHCR using `GITHUB_TOKEN`.
Local arm64 builds use the same recipe. The published image is amd64 only.
The smoke checks extension versions and isolated search queries; full search
acceptance belongs in the [data model](../design/data-model.md#search).

Each main-branch publish moves the tag to a new digest. Read the current digest
from the latest successful main-branch run, or from the GHCR package versions:

```sh
run=$(gh run list --workflow db-image.yml --branch main --event push --status success --limit 1 --json databaseId --jq '.[0].databaseId')
gh run view "$run" --log | grep -o 'tips-postgres@sha256:[0-9a-f]*' | sort -u
```

Deploy by registry manifest digest, not by tag. Verify an authenticated pull during
deployment setup. Use a credential with package read access and
`docker login --password-stdin`; keep credentials out of Compose and Git.
