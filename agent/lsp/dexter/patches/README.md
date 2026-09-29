# Local function-arity correction

This is the one local upstream patch authorized for this experiment. The base is
Dexter `cd099f31b7701803292584887bb614628f721b0a`. It does not change Codex,
Claude, the Python adapter's resolution behavior, or third-party libraries.

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

## Exact artifacts

- Base: `cd099f31b7701803292584887bb614628f721b0a`.
- Patch SHA-256: `cf465ffd10665d12838621fa7998d189e65abeeb22521b3813bfddddb10624ef`.
- Tested macOS arm64 binary SHA-256: `d4ac1fd543e5f3efd31876faa4e19e379c5e24836906c1b7333fd7f009ff0251`.
- Build: Go 1.26.3, `go build -trimpath -buildvcs=false ./cmd/`.

The combined patch touches 12 Go files: 2,619 added and 136 removed lines,
including 1,520 added test lines. It is one backend patch; it adds no integration process
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
signature-help overload handling, import `only:`/`except:` semantics in every
provider conflict, arbitrary macro expansion, or strict saved-index freshness.
Unknown syntax must be reported as an unverified boundary; a name-based fallback
is not proof of a correct result. The separate alias-shadowing code-action bug
is outside this patch.

The rename handlers themselves are unchanged, but their shared variable classifier
is corrected. Captures, pipe targets and mid-token cursors can now reach the existing
project-wide function rename instead of a mistaken local-variable rename. That
function rename still matches by name across argument counts. Do not use this
patch as evidence that renaming one overload is safe.

Identity references exclude occurrences whose module the static resolver cannot
establish. This can reduce recall compared with stock injector expansion. The
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
