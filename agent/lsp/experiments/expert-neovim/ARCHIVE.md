# Archived Expert + Neovim experiment

Date: 2026-09-24. Status: **archived research; not approved for rollout or merge**.

Branch: `experiment/expert-neovim-codex`.
Archive tag: `archive/expert-neovim-codex-2026-09-24`.
Application baseline: `81501387eb77b220c95693f58076f7f8255da1b0`.
Original experiment commit: `12590db`.

The tag identifies the archival snapshot, not a software release. Preserve the
existing history; follow-up experiments should branch from it and record new
results separately. Do not move the tag to make a later result look like the
original observation. No PR or merge to main is part of this archive.

## Decision and agent experience

The tested combination was installed Homebrew Expert 0.1.10, Neovim 0.12.5 and
published vv-mcp 0.3.4, with experimental external-edit synchronization. Keep it
optional for controlled exploration. It is not reliable enough to be the default
language-server workflow for agents implementing Tips.

| Finding | Agent impact | Conclusion at archive time |
|---|---|---|
| Rapid compilations shut down Expert's engine | Ordinary implementation turns into tool troubleshooting | Confirmed worker lifecycle mismatch; proposed fix not applied |
| Deleted callers remain indexed | Refactoring decisions can use stale references | Confirmed numeric delete-event / atom mismatch |
| Startup and empty responses are ambiguous | “Still starting” can be mistaken for “no usages” | Readiness/error presentation remains incomplete |
| Native disk edits do not behave like editor saves | Compiler feedback can remain stale | Experimental automatic buffer synchronization improved tested cases |
| Empty diagnostics do not establish latest-edit freshness | An agent can incorrectly treat silence as a clean compile | Revision-correlated feedback remains unproven |
| Five-second agent feedback hook is absent on this branch | Agent must explicitly request diagnostics | Delivery workflow remains incomplete |
| Full reindex calls overlap and fail | Automatic recovery can lose later requests | Rejected as the normal per-edit mechanism |

Warm error/repair feedback took roughly 1.5–2 seconds in tested successful cases;
isolated Tips file creation took about 5.4 seconds to appear in references. These
are individual observations, not latency guarantees. Worktree separation and
observed process cleanup passed. Several failures occurred with one editing client
in one worktree. No new actual Codex Sol or Claude cohort was run for Expert.

The prior ElixirLS/Sol work supplied acceptance scenarios; its full raw artifacts
are outside this archive. The relevant lessons are summarized in
[ROOT_CAUSES.md](ROOT_CAUSES.md). This snapshot preserves this Expert experiment's
15 recorded runs, including failures, inconclusive controls and corrected checks.

## Evidence and provenance

- [README.md](README.md): scope, observed results and local reproduction commands.
- [ROOT_CAUSES.md](ROOT_CAUSES.md): 5–8 whys per finding, source analysis and inversion tests.
- [REUSE.md](REUSE.md): reusable standards/tools and remaining adapter work.
- [versions.json](versions.json): installed versions, download provenance and checksums.
- [evidence.json](evidence.json): run summary, qualifications and portable `archived_path` entries.
- [evidence/MANIFEST.json](evidence/MANIFEST.json): original paths, original and archived SHA256,
  byte sizes and redaction counts for each captured artifact.
- [OTP supervisor trace](evidence/tips-validation/tips-supervisor-trace/engine-supervisor.trace):
  direct evidence of normal worker exits and the exhausted restart allowance.
- [Supplied Expert installation guide](evidence/upstream/expert-installation.txt):
  the downloaded text used in this experiment, preserved without Markdown link rewriting.

All 15 runs retain selected text evidence: result JSON, MCP transcripts, logs,
runtime Lua configurations, and the diagnostic supervisor trace. This includes
failed startup, the rejected full-reindex approach, and controls explicitly marked
inconclusive. A probe's exit code zero does not override failed semantic predicates.

Original `/private/tmp` paths are provenance, not archival dependencies. The
branch-relative copies are the retained evidence. Only runtime credential arguments
and structured cookie fields were redacted; original local files were not changed.
The manifest records checksums before and after transformation. A previously
redacted debug response remains redacted and is qualified in the run summary.

Binaries, dependencies, sockets, runtime registries, generated builds/indexes and
Git worktrees are omitted. Re-running requires provisioning the recorded tools;
the historical reproduction scripts still name their original local paths. This
archive is evidence retention, not a portable installer or a claim that the current
HEAD source exactly matches every earlier probe revision. Per-run Lua snapshots
and recorded requests preserve those variants where available.

## Verification and retrieval

Archive checks: every manifest SHA256 and byte count, JSON parsing, repository
documentation links, and a Gitleaks scan. Application checks were performed during
the experiment and retained under `evidence/tips-validation/application-checks`;
they were not rerun merely to archive documentation and captured output.

From the repository root, verify captured artifacts with Python's standard library:

```sh
python3 - <<'PY'
import hashlib, json
from pathlib import Path
root = Path('agent/lsp/experiments/expert-neovim')
manifest = json.loads((root / 'evidence/MANIFEST.json').read_text())
for entry in manifest['files']:
    data = (root / entry['path']).read_bytes()
    assert len(data) == entry['bytes'], entry['path']
    assert hashlib.sha256(data).hexdigest() == entry['archived_sha256'], entry['path']
print(f"Verified {len(manifest['files'])} artifacts")
PY
```

Retrieve the snapshot without merging it into any branch:

```sh
git fetch origin tag archive/expert-neovim-codex-2026-09-24
git worktree add --detach ../tips-expert-history archive/expert-neovim-codex-2026-09-24
```

The annotated-tag convention records the tagger, date and archival rationale in a
Git object: [Git's tagging documentation](https://git-scm.com/book/en/v2/Git-Basics-Tagging).
This is an unsigned archival tag; no cryptographic identity attestation is claimed.

## Conditions for a future experiment

Resolve the two Expert defects; then validate automatic synchronization and explicit
current/pending/failed/conflict feedback under a five-second delivery budget. Cover
cold startup, overlapping edits, HEEx/test files, branch changes and real model
workloads. Compilation, tests and Credo remain independent correctness checks.
Those are future acceptance conditions, not unfinished work on this archived branch.
