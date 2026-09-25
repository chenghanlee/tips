# Solution 2: direct LSP requests and explicit validation

Approved by the user on 2026-09-26. Branch: `experiment/elixirls-no-hooks`.
Worktree: `/private/tmp/tips-elixirls-no-hooks`.

## Baseline and status

Source checkpoint: `a388e4d` on `experiment/elixirls-codex-v2`, based on
`fd4e2da`. It preserves the previously uncommitted r24 implementation, patches,
tests, documentation and team-launcher changes. All 150 inventoried source files
were byte-identical in the old and new worktrees after creation. No runtime change
has been made in this experiment yet.

Frozen reference bundle:
`/private/tmp/tips-elixirls-codex-v2/agent/lsp/vendor/elixirls-neovim-beta-r24`.
Manifest SHA-256:
`b3e8891c33c0259a7b4f2210219e50e477c5e41aeb525e3834d91b8a3b7a640f`.
All 1,449 manifest entries were rechecked when this worktree was created.
Generated bundles, dependencies, build caches and raw evidence were not copied.
The old worktree and its evidence remain the reference and rollback option.

r24 G0-G6 passed. Actual Codex G7 phases 1-2 ran; phase 3 remains held.
Phase 2 delivered the warning twice, but hook-driven use was not demonstrated.
No beta admission, remote CI, push or merge is implied by this checkpoint.

## Contract

Keep hover, definition, references, document_symbols, workspace_symbols,
diagnostics and workspace_diagnostics. Each ordinary request returns its answer;
there is no separate submit-and-fetch protocol. Pending or failed work must remain
qualified, and can require a retry.

Remove this integration's automatic PostToolUse/Stop compiler feedback and its
delivery-only state. Keep disk synchronization, reconciliation, version matching,
error propagation, lifecycle ownership and recovery needed by direct requests.
Automatic feedback is intentionally lost; agents request LSP information and run
explicit validation before claiming their work is validated.

Do not substitute an automatic foreground compilation hook. Do not remove
unrelated user hooks silently. The launcher currently enables automatic Credo;
make that configuration choice explicit when defining the experiment's profile,
and retain explicit Credo validation.

## Implementation order and gates

1. Trace the hook's shared dependencies. Identify delivery-only fields and entry
   points before deleting them. Preserve the seven-operation contract. Prefer
   deleting code to introducing modes, new state or compatibility wrappers.
2. Establish an integration test for hook-free recovery: missed native watcher,
   rejected first notification, subsequent direct MCP request, and a fresh result.
   The existing reconciliation probe uses hooks and is insufficient evidence.
3. Remove hook provisioning, invocation and delivery-only code in this worktree.
   Test the generated launch configuration as well as the runtime. Keep the native
   watcher: it covers dependency changes outside the content scan.
4. Define explicit validation using the previous foreground-Mix investigation.
   Stock incremental Mix has a demonstrated sequential same-second stale result;
   do not call exit 0 proof of fresh compilation. Evaluate only the needed explicit
   check path and targeted invalidation, not the archived automatic hook mode.
   Separate cold preparation; report safety-timeout results as unfinished.
5. Run seven-operation and synchronization gates, including first-touch errors,
   edits during compilation, deletion/recreation, missing notifications, errors
   and honest pending states. Keep lifecycle/cleanup gates. A CLI compile does not
   refresh modules loaded in the language-server VM.
6. Compare with r24: warm request latency, edit/validation latency, cold preparation,
   retained state, components, custom patches and upstream maintenance obligations.
   Then run actual-agent acceptance. Do not infer improvement from line counts or
   compare different tasks/client versions as a controlled performance result.

Run the existing Ruff, strict Pyright and Lua checks on maintained core code, plus
affected upstream checks when upstream patches change. Use integration tests for
new acceptance behavior; do not rerun historical probes merely for volume.

## Boundaries and stop rules

- Empty references or symbols do not prove absence. Keep operation scope explicit.
- Explicit compilation is not tests, formatting, Credo or document parsing.
- Agent compliance with explicit validation is a workflow requirement, not an
  automatic guarantee. Record skipped validation as unfinished.
- Keep known r24 lifecycle and dependency-name collision limits visible.
- After two failed fixes, revisit the evidence and root cause before more changes.
- Prefer supported APIs and existing mechanisms. Reduce custom patches where
  correctness permits; zero patches is a stretch goal, not a claim or release gate.
- No merge to main until the new design passes its gates. Do not edit r24 artifacts
  or baseline application worktrees to make the experiment pass.

## Existing evidence to reuse

Paths below are under
`/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/beta-team/`:

- `combined-preparation/ROOT_HOOK_RCA.md`: source trace and historical hook evidence.
  It predates the Solution 2 choice; this document supersedes its proposed direction.
- `combined-preparation/p1/r24/GATES_RESULT.md` and
  `combined-preparation/peer-pS/PEER_R24_GATES.md`: baseline gates and peer review.
- `runtime/r24-accept/evidence/phase2/RESULT.md` and
  `combined-preparation/peer-pS/PEER_G7_PHASES.md`: actual delivery versus agent use.
- `dependency-recovery-boundary/peer-restart-pP/REVIEW.md`: restart alternative
  rejected as-is; do not restart that investigation without new evidence.

Foreground-Mix source and research are in Git at
`archive/plain-mix-compile-2026-09-25`, under
`agent/lsp/experiments/plain-mix-compile/`. Its measured behavior is not yet verified
in this new integration.

Historical `BETA_TEAM_TASKS.md` and r24 documents are checkpoint records. They do
not activate old assignments or establish acceptance of this experiment.
