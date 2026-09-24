# Minimal local Neovim/ElixirLS patch

Implemented on `experiment/elixirls-codex-v2`, 2026-09-24. The stack remains
vv-mcp 0.3.4 → Neovim 0.12.5 (`vim.lsp`) → ElixirLS 0.31.1. Normal file edits,
the five-second synchronous hook, and incremental compilation remain the contract.

## Ownership and behavior

- **Neovim configuration:** the assigned, canonical worktree is the explicit LSP
  root. Its native watcher excludes only that root's `tmp/` subtree. This uses
  the pinned, private `_poll_exclude_pattern` setting; no new watcher is added.
  A real-watcher test verifies the setting on this Neovim/macOS combination.
- **External edits:** observed hashes and pending synchronization are distinct.
  A failed reload or save remains pending, without increasing the edit generation.
  Successful files are removed individually. The hook retries pending work every
  200 ms within its existing deadline; later hooks/reads also retry. Unopened
  files continue through native watched-file notifications. Unsaved buffers are
  preserved. The scanner uses the same narrow `tmp/` exclusion.
- **Useful results:** hover, definition, references and diagnostic reads retain
  their results with `feedback` describing the observed build. Pending/failed
  compilation no longer rejects those results. A change during a request marks
  its result `superseded`. Empty pending results explicitly do not prove absence.
  Actual unavailable clients, failed synchronization and unsaved-buffer conflicts
  still prevent semantic reads; diagnostics remain available with qualification.
- **No permanent uncertainty state:** overlap does not disable later waits or
  navigation. Completed build observations permit normal service again. The
  observation is not proof of which bytes Mix compiled.
- **Small vv-mcp patch:** its compact success formatters otherwise discard
  `feedback`. [The patch](vv-mcp-feedback.patch) preserves it alongside existing
  JSON results and prefixes its message to Markdown results. This changes only
  one Rust source file, including its regression test. It does not replace MCP
  transport, LSP handling, result compaction or worktree routing.

These changes separate three facts previously conflated: seeing an edit is not
synchronizing it; build status is not result availability; scanner filtering is
not native watcher filtering. Reuse the existing mechanisms at each boundary.

## Verification

Raw output is under `tmp/elixirls-v2/minimal-patch/`. The retained result index
and source hashes are in [minimal-patch-evidence.json](minimal-patch-evidence.json).

| Boundary | Result |
| --- | --- |
| Reload failure and save failure, no second edit | Both retry successfully; no invented generation |
| One successful file and one failed file | Only the failed file is resent |
| Real ElixirLS save notification dropped once | Two attempts; compiler error delivered in 0.329 s |
| Persistent synchronization failure | Bounded wait, explicit status, later recovery |
| Pending/failed MCP hover, definitions, references, diagnostics | Useful results and qualification preserved |
| Empty results and edit during request | Explicit pending/absence warning or superseded status |
| Unsaved buffer vs external edit | Buffer preserved; qualified diagnostic access retained |
| Cold build then another edit and repair | Pending feedback, later errors, repair clears; no latch |
| Native watcher fixture create/change/delete | Zero fixture notifications and zero builds |
| Source, config and external-template watcher controls | Notifications still delivered |
| Queried file error and repair | Approximately 0.320 s and 0.298 s |
| Eight/fifteen-second builds | Pending feedback at 4.79–4.80 s |
| Stalled RPC and concurrent/expired hooks | Under 5 s; expired Stop preserves later delivery |
| Worktree isolation, atomic replacement, failed tool hook | Existing integration regressions pass |
| EOF, killed launcher and normal exit | Observed owned descendants exit |
| vv-mcp checks | 58 tests and Clippy with warnings denied pass |
| Patch and scripts | Patch reapplies exactly; Python syntax checks pass |

The six initial synchronization/policy boundary tests failed before the changes.
The Rust formatter regression and actual MCP transport also reproduced stripped
feedback before patching the binary. The final boundary suite has nine cases.

Local Tips workload replays used the existing, isolated second-cohort worktrees
and their completed application changes. These were deterministic test runs with
live Neovim/ElixirLS, not another model-driven three-agent cohort:

| Workload | Tests | Fixture notification batches | ElixirLS builds during tests |
| --- | --- | --- | --- |
| Provider config and search probe | 26 passed, 1 excluded | 0 | 0 |
| Media schema | 30 passed | 0 | 0 |
| Health controller | 4 passed | 0 | 0 |

Every workload also returned qualified workspace diagnostics and cleaned up its
owned processes. No Tips application source was changed for these replays.

Two early replay assertions assumed that build completion immediately ends the
diagnostic quiet window. Late diagnostic publication legitimately reported pending;
the assertions were corrected to respect that existing window. The first Rust
suite invocation lacked Neovim on PATH; rerunning with the pinned Neovim passed
all 58 tests. Early runtime replay outputs are retained; the final Rust log records
the corrected invocation.

## Reuse and reproduction

Use the existing launcher with this experiment's Lua modules and a patched binary.
The tested vendor directory is `tmp/elixirls-v2/minimal-patch/vendor`; the earlier
`tmp/elixirls-v2/neovim-vendor` remains the unmodified baseline. Toolchain installation
for this build was confined to the disposable experiment output directory.

[vv-mcp-feedback.json](vv-mcp-feedback.json) pins the source commit, archive,
original source-file hash, patch hash, and tested binary hash. The downloaded
commit's complete source tree was compared with the previously tested vendor tree.
Their directory labels differ, but all file contents match.

In a fresh source checkout of vv-mcp commit
`b64e27e1d0f1a95984512c11a1ca7ad31208e8dd`, with Rust 1.97.0 and the pinned Neovim
on PATH:

```sh
patch -p1 < /absolute/path/to/vv-mcp-feedback.patch
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo build --locked --release
```

Use `target/release/vv-mcp` as the vendor's `vv-mcp`. Keep the existing launcher,
registry isolation, and Lua initialization. Example probe from this Tips worktree:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_patch_probe.py \
  --vendor tmp/elixirls-v2/minimal-patch/vendor \
  --output tmp/elixirls-v2/minimal-patch/new-replay
```

Other retained probes cover cold startup, hook budgets, delivery, lifecycle,
worktree isolation, and the local Tips workload replay. Raw traces contain both
real compiler cases and explicitly labelled fault-injection cases.

## Remaining limit

The reproduced overlapping-write Mix invalidation defect is not repaired here.
There is no automatic clean, forced recompilation, restart, or compiler patch.
`current` means the last observed build completed for the adapter's generation;
it does not certify compiler input bytes. Normal compilation and tests remain
necessary, and the existing overlap reproductions remain relevant evidence.

This is a validated experiment patch, not an active Codex/Claude rollout. Active
client configurations and the main checkout's unrelated Claude work were untouched.
