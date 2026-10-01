# Dexter local patch

`dexter-go.patch` is the one cumulative Go patch this project carries on Dexter
`c4b62b788bbe38f0af507a79f0d6de46dd812b51` (0.7.2). Root exports it from the
source branch; nobody edits it by hand.

## Build identity

`../build.sh <dexter-git-repo>` takes a `git archive` of the pin, applies the
patch in a copy, and builds with
`-ldflags "-X github.com/remoteoss/dexter/internal/version.LocalBuildID=<id>"`
where `<id>` is the SHA-256 of the bytes `"<pin>\n<patch sha256>\n"`. It
asserts that `dexter version` reports that id, then writes
`../vendor/build.json` (upstream, patch sha, id, binary sha, Go version).
A frontend and a daemon with different ids refuse each other, so stop a
worktree's daemon with its current `.dexter/dexter.sh stop` before replacing
the binary, and re-provision afterwards. The build checks for running daemons
before compilation and immediately before installing the verified binary;
failed process inspection aborts the build. Keep agents stopped during the build.

## What the patch adds

- `query <operation> <file> <line> <column>`: positional read-only requests on
  the workspace daemon, the nine operations in the
  [LSP guide](../../README.md#operations), `--wait` for a cold index,
  1-based UTF-16 input, raw LSP JSON output.
- Arity-aware definition, hover, references and call hierarchy; references
  through explicit imports; incoming calls credited to their lexical owner
  (def clause, `test`, `setup`, `setup_all`); one outgoing site per call
  occurrence across every clause, guards and defaults included.
- File-backed navigation is disk-authoritative. Notifications invalidate
  cached snapshots; reads load disk text and follow later changes by size and
  mtime. Unsaved editor buffers are not supported.
- Root admission: the exact checkout (a `.git` checkout or a Mix project
  with `mix.exs`; a directory holding only an index is refused), its
  dependency sources and the configured Elixir sources; anything else is
  refused.
- The build identity handshake above.

## Retained tests

Run in the source tree with `go test ./... -count=1`; CI does the same on the
pin plus patch. By behaviour, with the test files that hold them:

- Arity-aware navigation: `internal/lsp/arity_integration_test.go`
  (`TestArity_InversionMatrix` is the matrix), `internal/lsp/hover_test.go`,
  `internal/lsp/server_test.go`, `internal/treesitter/arity_test.go`.
- References through imports: `internal/lsp/import_references_test.go`.
- Call hierarchy owners and sites: `internal/lsp/call_hierarchy_test.go`
  (`TestCallHierarchyIncomingOwners` and `TestCallHierarchyOutgoing` are the
  fixtures' matrices), `internal/lsp/call_hierarchy_generated_arity_test.go`,
  `internal/lsp/call_hierarchy_target_test.go`.
- Disk-backed documents and notification ordering: `internal/lsp/documents_test.go`,
  `internal/workspace/saved_file_sync_test.go`.
- Build identity handshake: `internal/daemon/*_test.go`.
- `query` contract, root admission and library navigation:
  `query_integration_test.go`, `lsp_integration_test.go`.
- Nested checkout exclusion and watcher events:
  `internal/workspace/nested_checkout_test.go`,
  `internal/workspace/nested_checkout_darwin_test.go`, `internal/parser/parser_test.go`.

The build-script safety checks run from Tips with
`python3 agent/lsp/dexter/test_build.py`.

The Elixir fixtures under `internal/lsp/testdata/` are the recorded cases;
correctness is claimed for those constructs and no others.

## Limits

- Nested checkouts are excluded from indexing and watching. Request membership
  checks still refuse their files; dependency sources remain available.
- A root reached through a symlink is admitted only under the exact spelling
  it was bound with.
- Not offered: rename, code actions, formatting, type definition, strict
  freshness. Nothing here is a compatibility promise toward any earlier
  adapter or fix.

## Required Go static analysis

Every Go change, including test code and this carried patch, must run the
`tiny_big_agents` custom golangci-lint profile. Upstream `make lint` alone
is insufficient. [tba-golangci.yml](tba-golangci.yml) retains its analyzers
(including Staticcheck and NilAway) and thresholds. The only adaptations are
Dexter's NilAway module prefix, module-relative paths, and removal of TBA-only
path exemptions that would otherwise exclude Dexter from complexity/clone checks.

Use custom golangci-lint **v2.12.2**, built with Go **1.26.3**, and the NilAway
module plugin `go.uber.org/nilaway/cmd/gclplugin` at
`v0.0.0-20260515015210-fd187751154f`, matching TBA's `.custom-gcl.yml`. Reuse
TBA's `.agent-runs/.cache/golangci-lint/custom-gcl` when available; a stock
golangci-lint binary cannot run this plugin.

From the patched Dexter source root, set `CUSTOM_GCL` to that executable and
`TBA_LINT_CONFIG` to the absolute path of this directory's `tba-golangci.yml`:

```sh
"$CUSTOM_GCL" run --config "$TBA_LINT_CONFIG" \
  --max-issues-per-linter 0 --max-same-issues 0 --uniq-by-line=false \
  --output.json.path /tmp/dexter-lint.json ./...
```

Run the same profile on the unchanged pin when attributing findings. Compare
by analyzer, function/source and diagnostic, accounting for shifted lines.
Fix issues introduced by our code; report inherited findings and any increases
in existing function complexity explicitly. Do not suppress rules or rewrite
unrelated upstream code to get a green total. Root records the totals for each
export in its acceptance message; this file keeps no running tally.
