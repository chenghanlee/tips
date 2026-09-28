# Dexter for Tips

**Experimental integration.** Claude and Codex both use Dexter's stock command-line
interface for named Elixir navigation. The limits below apply.

Tips uses unmodified [Dexter](https://github.com/remoteoss/dexter) to find Elixir
definitions and references. Both clients run its `lookup` and `references`
commands in a normal shell. Tips sessions disable Dexter's native LSP plugin.
Hover, diagnostics and cursor-position requests are not provided.
This integration adds no MCP bridge, wrapper, Neovim adapter, compilation hook or local server patch.

Why not the native plugin: in our test, it kept its own copy of each queried file.
Claude's Edit tool updated that copy; a shell edit (`sed`, `mix format`, generators)
left it stale, while the CLI returned the new location from the updated index.

## Install

Install Git and Go 1.26.1 or newer. From the main checkout:

```sh
agent/lsp/install_dexter.sh
```

The installer builds the exact upstream commit in [dexter.rev](dexter.rev),
without modifying its source. This is an unreleased upstream revision containing
the shared workspace daemon; the binary's version string alone does not identify it. To use a shared
installation elsewhere, set `TIPS_ELIXIR_TOOLS` before installing and launching.

`vendor/` is Git-ignored. Rebuild after changing the pin and restart clients before
using the new binary. Do not mix server versions or upgrade a running workspace's
daemon in place. The helper uses this pinned path, not an arbitrary system Dexter.

## Use with agent teams

From the assigned worktree root, both clients run:

```sh
"$TIPS_ELIXIR_TOOLS/bin/dexter" --root "$PWD" lookup --strict --wait 30s Module function
"$TIPS_ELIXIR_TOOLS/bin/dexter" --root "$PWD" references --wait 30s Module function
```

The [team helper](../teams/README.md) sets `TIPS_ELIXIR_TOOLS` to the installation
path; it does not change `PATH`. Codex receives it and the team's other values
through its supported `shell_environment_policy.set` config. This keeps the
shell's database partition explicit even with a shared Codex daemon.

Claude's launch passes the generated `.claude/settings.local.json` with `--settings`.
It disables Dexter's native plugin, the old Expert plugin and automatic Mix plugins
for that session. A linked worktree may read local settings from the main checkout,
so the helper names the file explicitly. Coordinator sessions disable the native
plugin too; they do not initialize or own an index.
Normal formatting, compilation, Credo and tests remain explicit project checks.

## Use directly

In your terminal, prepare the worktree and start Claude with Dexter's native plugin
disabled for this new session only. For Codex, run `codex` instead of the last line.

```sh
cd /absolute/path/to/tips-worktree

# Once per new worktree, before querying (omit if already initialized).
/absolute/path/to/main/agent/lsp/vendor/bin/dexter init "$PWD"

claude --settings '{"enabledPlugins":{"dexter-lsp@dexter":false}}'
```

Inside the agent's shell, both clients query with the pinned binary's absolute path:

```sh
/absolute/path/to/main/agent/lsp/vendor/bin/dexter --root "$PWD" lookup --strict --wait 30s Tips.ProviderConfig
/absolute/path/to/main/agent/lsp/vendor/bin/dexter --root "$PWD" references --wait 30s Tips.ProviderConfig
```

The `--settings` flag changes only that session and leaves the global plugin
installed. It does not override a managed policy that requires the plugin. It keeps
your other plugins, including automatic Mix plugins. The CLI still starts Dexter's
daemon and BEAM helper; in our Homebrew 0.7.2 test, that helper made the
`mix-compile` hook skip compilation. Run project checks explicitly.
A coordinator that needs ad hoc navigation uses these direct instructions.

Team sessions get `TIPS_ELIXIR_TOOLS` from the helper. A direct launch may not
inherit exports from its terminal under a shared Codex daemon, so use the absolute
path. Do not assume bare `dexter` selects this installation.

Optional: to avoid passing the flag each launch, run
`claude plugin disable dexter-lsp@dexter --scope local`. Local scope applies to this
project on your machine; in a linked worktree, Claude may store it at the main
checkout, which affects all its worktrees. Undo it with
`claude plugin enable dexter-lsp@dexter --scope local`. The per-session flag is the default.

The team helper performs the initial `init` automatically. It matters for nested
worktrees: this Dexter revision can otherwise prefer an ancestor's existing index
over a nearer Git/Mix root, even with `--root`. Do not delete `.dexter/` while a
client is running. Reinitialize before querying again if you removed it.

For a function, append its name after the module. `lookup --strict` prevents fuzzy name
matching. CLI arguments name a module and optionally a function; they do not select
an arity or resolve an expression at a call site. Resolve aliases and imports from
source, then inspect the returned source before edits.
Lookup follows `defdelegate` to its target by default. Add `--no-follow-delegates`
when you want the delegating function's own declaration.
`references Module` finds uses of the module itself, not all calls to its functions;
name the function to find its callers.

## What the results mean

Dexter owns parsing, indexing, watching and readiness. `--wait 30s` bounds initial
index waiting; it does not certify that an answer includes a particular edit.
Both empty and non-empty results can be incomplete. If initial indexing takes
longer than the wait, the pinned CLI can return a non-empty subset without a warning.
Successful exit and silence do not prove indexing finished. Wait for the command
to exit before reading its result. If a result disagrees with source, report the
limit and inspect the source; do not repeat the query until it agrees.

The pinned revision indexes Git-ignored source copies under `tmp/`, including
files created by Tips' own tests, producing duplicate locations. A copy can
appear first. There is no stock exclusion setting in this revision. Check the
path before editing; keep future copied projects outside the working repository.

Homebrew `dexter-lsp` 0.7.2 is not a supported substitute: it has no `stop`,
`--root` or `--wait`.

Startup found ordinary offline edits, but queries immediately after a live write
returned stale or missing results in our multi-worktree test. `--wait` waits for
startup indexing, not for each edit; a later shell command is not a freshness
guarantee either.

For a known changed file that still returns an old answer, run
`reindex path/to/file.ex` with the same pinned binary and workspace root used for
navigation, then inspect the returned source. This recovered the tested offline
edit that preserved size and modification time. Use the file form: bare or
directory `reindex` uses modification times and can skip such edits. Reindex
completion is not proof that parsing and index writes succeeded. It is recovery
for an observed problem, not a required step after every edit. `init --force`
deletes and rebuilds the whole index and requires the workspace to be released;
it is not needed for this tested recovery.

Dexter parses source and may approximate generated code using compiled artifacts.
`--strict` prevents fuzzy name matching but can still return a module declaration
for a BEAM-derived function, without marking it as approximate. Our reference tests
missed a delegated caller and protocol/behaviour implementation callers reached
through dynamic dispatch. A real Tips query also missed the local capture
`&fetch_api_key/0`; exit 1 with "No references found" does not prove there are no callers.
Navigation is useful evidence, not a replacement for
compilation or tests, and a successful compile
does not certify reference completeness. There is no required per-file diagnostic
ritual or synthetic global `current` label.

## Stop and change workspaces

Dexter shares one daemon/index per workspace. Index files live in `.dexter/`; a CLI
query can leave an intentionally idle daemon. Closing a frontend need not stop it.
Before deleting or repurposing a workspace, use the supported command:

```sh
/absolute/path/to/main/agent/lsp/vendor/bin/dexter --root /absolute/path/to/tips-worktree stop
```

This refuses while clients remain attached. Close those clients and retry; do not
force another agent off the workspace. The team helper uses this same non-forced
command during teardown and before reconfiguring an unowned worktree. A refusal
preserves the worktree. It does not certify unrelated shell jobs have finished.
Stopping a coordinator in the main checkout leaves that shared index alone;
the coordinator does not own other users' main-checkout sessions.

If `.dexter/` exists without `dexter.db`, the helper refuses reuse or cleanup:
Dexter's root discovery could otherwise select an ancestor's index. Close the
affected clients and have the operator verify that no Dexter process owns that
worktree before removing the incomplete `.dexter/` directory and rerunning setup.
Do not use `dexter stop --root` to repair this missing-marker case.

## Check changes

```sh
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
pyright -p agent/teams/pyproject.toml
python3 scripts/check_docs.py
```

On an upstream bump, test real CLI navigation from both clients, external edits,
same-named isolated workspaces, and the non-forced stop contract. Keep the server
unmodified; report upstream defects instead of growing a compatibility layer.
