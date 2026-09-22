# Elixir language server

Codex and Claude use Expert through an MCP bridge. Each coding client runs its own
bridge and Expert in its assigned worktree. Clients share installed binaries and
the engine preparation cache. TPMs run without an LSP.

## Files

| File | Purpose |
|---|---|
| `launch_worktree_lsp.sh` | Start the bridge and Expert in the supplied worktree. |
| `build_install_expert.sh` | Build, test and install patched Expert. |
| `build_install_mcp_bridge.sh` | Build, test and install the patched MCP bridge. |
| `expert-reference-results.patch` | Distinguish reference results, index readiness and failures. |
| `expert-worktree-isolation.patch` | Isolate project indexes and serialize shared engine preparation. |
| `mcp-bridge-tools-and-lifecycle.patch` | Fix navigation, document synchronization, deadlines and process cleanup. |

Existing installed binaries can run without the patch files. A new teammate needs
the patches to reproduce those working binaries. Deleting them would leave our
fixes only inside the current installation, unless recovered from Git history.
Keep the patches with the build scripts.

## Build and validate

Install the tools listed in the [local development guide](../../docs/development/local-development.md).
Builds also require Git, Bash, `patch`, Python 3.11+, Go and `unbuffer` (Expect).
Build from a worktree and set the shared installation directory explicitly:

```bash
export TIPS_ELIXIR_TOOLS=/absolute/path/to/main/.elixir-tools
agent/lsp/build_install_expert.sh
agent/lsp/build_install_mcp_bridge.sh
```

The scripts fetch pinned sources, apply patches and run affected tests before
installation. Expert installs a versioned release; the bridge replaces its binary
atomically. An existing Expert release is not overwritten. Installing tools does
not restart clients. Restart a client to load new binaries.

## Start and use

Use the [team workflow](../teams/README.md) to provision and launch clients.
The helper generates the selected client's config from [config.toml](../teams/config.toml).
It calls the main checkout's wrapper with the assigned absolute worktree path.
Older review commits do not need their own copy of the wrapper.

Configure the MCP client to invoke the wrapper with its worktree path:

```bash
/absolute/path/to/main/agent/lsp/launch_worktree_lsp.sh /absolute/path/to/worktree
```

It finds binaries in the main checkout's `.elixir-tools/bin`, unless
`TIPS_ELIXIR_TOOLS` specifies another tools directory. Install Mix dependencies
in each worktree. Elixir and Erlang must be on the client's `PATH`.

- Brief agents after client launch. Expert builds and indexes in the background.
- Do not add a compile-ready gate or start another LSP as a probe.
- Stop the client and verify all owned descendants exit before advancing a review
  checkout or deleting its worktree. Conversation reset does not reroot the LSP.
- After wrapper path changes, regenerate client configs before their next launch.
  Update standalone client configs when the new path exists in main.

## Tool behavior

- Source files must belong to the Expert session's workspace. An outside file
  returns a workspace-mismatch error with both paths. Use a session rooted at
  that file's project; retrying the current session will not load it.
  Definition results may still point to external dependency source files.
- `definition`, `references` and `hover` take `filePath`, `line` and `column`.
  Positions are 1-based; columns use UTF-16 code units.
- References belong to the project selected by the source file. Query a call site
  in the application to find its uses of a dependency.
- References retry only `index_not_ready`. Other failures and timeouts are errors,
  not successful empty results.
- Keep the client tool timeout aligned with the bridge's compiled deadline.
  The helper rejects a conflicting setting. Queued calls can wait before that
  handler deadline starts.
- Diagnostics without document versions cannot confirm an exact edit match.
  A timeout can leave stale diagnostics. Inspect the reported result.
- Expert logs are in the assigned worktree's `.expert/` directory.

## Check changes

```bash
python3 agent/teams/test_task_worktree.py
python3 agent/teams/test_team.py
```

Before adopting launcher or tool changes, pilot both real clients in disposable
worktrees. Check client cwd, actual LSP workspace, exact reference results,
reviewer revision advance and complete descendant exit. Config inspection alone
does not prove the running root. Do not infer full team capacity from a small pilot.

In the same pilot, each client must create a file and use its normal shell to
stage, commit and push to a disposable remote. Verify clean worktrees, matching
local/remote SHAs and receipt of the explicit Herdr handoff. Preserve permission
errors and report them to the TPM; do not use an API workaround. Follow the
[handoff instructions](../teams/README.md#context-and-handoff). No hooks or `--wait`.
