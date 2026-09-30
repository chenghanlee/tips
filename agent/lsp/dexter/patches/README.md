# Local Dexter correction

This is the one local upstream patch authorized for this experiment. The base is
Dexter `cd099f31b7701803292584887bb614628f721b0a`. It began as the function-arity
correction below. On 2026-09-30 the human separately approved extending the same
patch for reference discovery and local types; see
[that section](#reference-discovery-and-local-types-2026-09-30). It does not
change Codex, Claude, the Python adapter's resolution behavior, or third-party
libraries.

## Problem and approach

Elixir distinguishes functions by module, name and number of arguments. The
stock server sometimes chooses by name alone. For example, a call to `create/3`
can resolve to `create/2`; references can combine callers and declarations of
both functions. Choosing a module by name before checking arguments can also
select a local function instead of the imported function the call actually uses.

The correction carries the argument count through the existing definition,
hover and reference paths, and selects the called arity when preparing a
generated callable for call hierarchy. It uses the existing Elixir grammar to identify
calls, pipes, keyword arguments, blocks, captures and declaration defaults.
Reference candidates are checked against the module and argument count of the
same source occurrence. No second resolver, index, service or schema migration
is added to the integration.

Verified call references use the function token's range, converted to the
negotiated LSP position encoding. Declaration locations may still be line-level.
The stock CLI's name-based searches retain their existing meaning.

## Initial validation — 2026-09-30

The reproduced argument-count failures pass with the patch. This is a bounded
correction, not production adoption or proof that all Elixir constructs resolve
correctly. Fable reviewed the design and implementation; one Opus agent wrote
independent compiler-backed acceptance tests, and the other implemented the fix.
The principal review added the same-line provider inversion and caught a renamed
delegate-chain defect before packaging.

| Check | Result |
| --- | --- |
| Public-handler arity matrix | 86 subtests in 5 test groups pass; stock failures recorded before implementation |
| Independent raw LSP and `dx` | All 33 cases agree and return the compiler-backed expected answers |
| Open versus saved files | Identical answers for the three explicit open-document controls |
| Unicode | Definition and exact UTF-16 reference spans pass with accented text and emoji before calls |
| Adapter suite on the packaged binary | 25 passed, no skips |
| Go suites | Full ordinary suite passed before the final delegate correction; all affected packages and full race suite passed after it |
| Go vet, formatting, modules | Vet and gofmt clean; module verification and tidy diff clean |
| Python and build wrapper | Ruff 0.16.8, formatting, strict Pyright, shellcheck and documentation links pass |
| Rebuild provenance | Independent build from stock plus this patch reproduces the packaged binary checksum |

The cases cover both argument-count directions and declaration orders, local and
qualified calls, imports, a static use chain, default arguments, pipes, captures,
anonymous functions, keyword arguments, no-parentheses calls, do blocks, multiple
calls on one line, undefined calls, callbacks/specs, and delegates with defaults
and renamed intermediate functions. Single-arity and real type-use controls stay
correct. The compiler trace and runtime checks supply expectations independently
of the new parser helper.

Two stock expectations were corrected, with controls retained: a three-argument
`schema` call targets the private `/3`, and Hammox and Mox callers belong to their
own providers even when both functions have arity three.

### Inversion checks

Four deliberate defects were introduced separately in disposable copies. All
were caught by the handler matrix:

| Deliberately broken rule | Failing cases |
| --- | ---: |
| Provider selection ignores argument count | 5 |
| Buffer definition selection ignores argument count | 15 |
| References ignore argument count | 26 |
| Module and argument count need not belong to the same occurrence | 1 |

The last case places `Alpha.f/2` and `Beta.f/3` on one line and rejects that line
as a reference to `Alpha.f/3`. The final delegate correction does not change any
of these four mutation sites. A separate new regression caught that correction:
a delegate renamed with `as:` must use its current name when reading a downstream
defaulted head.

### Static analysis

We reused the other local project's custom golangci-lint 2.12.2 profile,
including NilAway, security checks, and cognitive/cyclomatic limits of 20.
Only its module prefix, relative-path base and project-specific exclusions were
adapted for Dexter. The rules and limits were not relaxed.

The strict profile reports **1,459 findings**, compared with **1,463 on stock**.
There are no findings in the new arity source/test files. Existing large functions
remain above the limit: `findDefinition` cognitive complexity changes from 31 to
33 and `ReferenceNames` from 40 to 41 (cyclomatic 26 to 27). Other touched large
handlers stay equal or decrease. These are recorded costs; unrelated upstream
code was not changed to clear inherited findings.

The upstream lint profile passes with the recovered analyzer built with Go
1.26.3. The installed Go-1.26.2-built analyzer disagrees, reporting possible nil
access after fatal test assertions, including two untouched tests. No suppression
was added. Standalone Staticcheck reports the same three stock deprecation
warnings (`Temporary` and two `RootURI` uses). This is not an all-tools-clean claim.

### Measured cost

Occurrence verification reparses candidate files. On the first green build
(`53502423`), warm reference requests on ten names in a 93-file Tips checkout without dependencies took **7.5–30 ms**, versus
**0.46–1.06 ms** on stock. With 2,760 dependency source files, the `Enum.each`
query returned the same 221 locations across 165 files but took a median
**822 ms**, versus **3.4 ms** on stock (three warm repeats). A later frozen-build
check (`88a94072`) took 782 ms. These are request timings, not cold-index or complete `dx`
workflow timings. No cache or second index was added.

## Generated Repo arity follow-up — 2026-09-30

`Repo.query!(sql, [])` still appeared as `query!/1` in call-hierarchy preparation
with the original arity patch. This handler used the first compiled export.
It now filters generated exports using the existing cursor-arity helper before
constructing the item. The production change is eight added Go lines, including
four comment lines. There is no new parser, dependency, schema or process.

The six handler regressions cover `/1`, `/2`, `/3`, a pipe, a capture, and a known
unsupported arity. The original implementation failed five; all six pass now.
A known arity with no matching export returns no item. Unknown arity retains
the existing name-based behavior. Consumer module anchors remain unchanged.

The unchanged real-Ecto fixture (Ecto 3.14.2, ecto_sql 3.14.0) returns the same
nine expected calls with zero label mismatches: `query!(sql, [])` now reports
`/2`, while `query!(sql)` stays `/1`. No database was started or queried.
The rebuilt package matches the binary used for this check byte for byte.
The full Go suite, `go vet`, upstream lint configuration, formatting and module
tidy diff pass; the packaged adapter suite passes all 25 tests without skips.
Sandboxed attempts failed cache/process access; the normal-permission runs pass.
Evidence is in `tmp/dexter-arity-patch/repo-arity-followup/` in the main checkout.

This is a generated-item preparation fix. Source-defined preparation still uses
the first definition row. Incoming/outgoing follow-ups still use module and
function name without arity; correct labels do not make those graphs arity-aware.
The outgoing prototype also groups by module and function, so sites of different
arities can still share one label. Those are separate limitations.

## Reference discovery and local types (2026-09-30)

Purpose: three reference and type lookups that returned nothing or dropped rows
on the ordinary path. In a file that imports the module, the indexer had no row
for a bare capture (`&normalize/1`) or a bare call after a one-line head, and
the query scanned whole files only when they define the function. With
`alias Refs.Target, as: T` then `import T`, the arity patch's per-occurrence
module filter read the written name `T` and rejected a row stock kept.
`TypeDefinition` looked up a bare local `t()` with an empty module qualifier.
Root-cause record: main checkout `tmp/dexter-reference-triage/TRIAGE.md`.

Change: files with an import row for the target module join the existing
occurrence scan and module/arity filter; import names resolve through the
existing alias map before that filter; `TypeDefinition` uses the enclosing
module for a bare name inside a typespec and keeps the qualified path. No
parser, resolver, index, service, schema or process is added; defining files
and indexed rows are processed as before, and there is no whole-workspace scan.
Production change: 21 added and 3 removed lines in `arity_navigation.go` and
`server.go`, plus one 242-line regression test file.


On the saved fixture all 40 reference executions and 14 of 15 type-definition
queries match the fixed oracle; the one wrong row is the type parameter `t` of
`@type wrap(t)`, which resolves to the module's `@type t`. Details and checks:
[VALIDATION.md](../VALIDATION.md#references-and-local-types-2026-09-30).

Boundaries: no type-parameter scoping; `use`-injected consumers without an
import row are outside the change, and imported calls inside interpolation are
unverified. The alias fix changes the shared bare-name provider resolution that
definition, hover, call-hierarchy preparation and rename also use; no
rename-safety guarantee follows, and freshness is unchanged. The cost of
scanning importing files on a large repository is unmeasured.

## Exact artifacts

- Base: `cd099f31b7701803292584887bb614628f721b0a`.
- Patched source: Dexter branch `fix/reference-imports-local-types` at `6e38b3c`;
  `git diff cd099f31..6e38b3c` is the packaged patch.
- Patch SHA-256: `6fa219e14159b2a454060104143c54a686ce604bcae233506aaa6de4dcdf762a`.
- macOS arm64 binary SHA-256: `7f01cbf2807e7b1ff1eb668fc3550aa9008198210e32d71c1b94383a2cc60fca`,
  built with `build.sh` from the stock archive plus this patch; `vendor/build.json`
  records both checksums.
- Build: Go 1.26.3, `go build -trimpath -buildvcs=false ./cmd/`.
- Superseded arity-only artifacts: patch `cf465ffd…`, binary `d4ac1fd5…`.

The patch touches 13 Go files: 2,879 added and 136 removed lines, most of them
tests. It is one backend patch; it adds no integration process
or library dependency. Keep its regression tests when re-pinning.

Detailed local evidence is in the main checkout's ignored
`tmp/dexter-arity-patch/`: `evidence-p14/FINAL-1fed2fbf.txt`,
`evidence-p14/probe-results-1fed2fbf/`, `evidence-p14/mutants/`,
`packaged-adapter-tests.log`, `packaged-source-race.log`, and
`packaged-source-tba-lint.json`. The analysis setup and baseline comparison are
in `STATIC_ANALYSIS.md` and `tba-golangci.yml` there. Test daemons used fresh roots;
the serving daemon executable and checksum were checked, and those daemons were
stopped. No existing team's binary or daemon was replaced.

## Boundaries

This change does not establish safe multi-arity rename, complete call hierarchy,
complete reference discovery, signature-help overload handling, import
`only:`/`except:` semantics in every provider conflict, arbitrary macro expansion,
or strict saved-index freshness.
Unknown syntax must be reported as an unverified boundary; a name-based fallback
is not proof of a correct result. The separate alias-shadowing code-action bug
is outside this patch.

The rename handlers themselves are unchanged, but their shared variable classifier
is corrected. Captures, pipe targets and mid-token cursors can now reach the existing
project-wide function rename instead of a mistaken local-variable rename. That
function rename still matches by name across argument counts. Do not use this
patch as evidence that renaming one overload is safe.

Identity references exclude occurrences whose module the static resolver cannot
establish. This can reduce recall compared with stock injector expansion; the
aliased-import case of that exclusion is closed by the extension, `use`-injected
consumers without an import row are not. The
Hammox/Mox regression deliberately excludes calls resolving to the other provider;
it is a module-identity correction even though both calls have three arguments.
A callback head is its own declaration for definition and hover; references at
callback heads retain the stock name search.

## Build and maintenance

Run the parent directory's `build.sh` against a clean checkout of the base
revision. It applies `function-arity.patch` only in a temporary copy and records
the base revision, patch checksum and binary checksum in `vendor/build.json`.

Before running the build script over an active binary, stop each team's daemon
with its existing bound command. Then build, refresh the bound commands' checksums
by re-provisioning, and start the new build. The protocol version is unchanged, so a new frontend
can otherwise attach to an old daemon and still return the old answers.

When changing the upstream pin, review whether upstream fixed these cases, run
the retained regression and inversion checks, and remove this patch if it is no
longer needed. A patch that applies cleanly is not sufficient evidence.

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

Run the same profile on the unchanged base when attributing findings. Compare
by analyzer, function/source and diagnostic, accounting for shifted lines.
Fix issues introduced by our code; report inherited findings and any increases
in existing function complexity explicitly. Do not suppress rules or rewrite
unrelated upstream code to get a green total. Record tool/profile changes when
updating these pins.

Latest check (2026-09-30, source `6e38b3c`): **1,460 findings**, including
24 NilAway reports, versus **1,461** on parent `8f03fa4` under this same
profile. After normalizing shifted diagnostic lines, the only difference is
the fixed `filepath.Join` argument in our generated-arity test. The six
regressions pass, and rebuilding produces the unchanged binary checksum.
The earlier generated-arity change puts `PrepareCallHierarchy` cognitive
complexity at **22**, above the limit of 20; it remains a reported cost, not
a clean gate. No finding occurs in the new references/type test or
`arity_navigation.go`. No unrelated upstream implementation was changed.

The first run reported five additional gosec taint findings in unchanged
functions; they did not recur in the final run. Their cause is not established;
the initial report is retained, not counted as five repaired defects. Detailed
reports and the normalized comparison are in the main checkout's
`tmp/dexter-reference-triage/patch-followup/root-checks/tba-*.{json,log}`.
