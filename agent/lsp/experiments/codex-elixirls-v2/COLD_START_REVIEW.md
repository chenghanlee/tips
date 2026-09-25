# Cold-start performance review and seed experiments

2026-09-25. Review of Opus's G1 proposal, with beta-r7 on a disposable Tips worktree.
No cache feature was enabled in the maintained launcher or worktree generator.

## Finding

Dependency reuse is the largest measured cold-start opportunity. However, copying
compiled dependencies from another worktree also copies source-path metadata.
The copied module can send definition requests back into that donor worktree.
The proposed cross-worktree cache is fast, but not behavior-preserving as written.

The smaller tested candidate is to reuse dependencies already compiled by normal
Mix **in the same worktree**, copying only dependency build directories into the
private ElixirLS build directory. This avoids duplicate compilation without moving
the dependency source paths or sharing writable build state.

## Root problem: eight whys

1. Why does cold readiness take roughly a minute? ElixirLS compiles dependencies.
2. Why is this repeated in each worktree? Each owns its private build directory.
3. Why can the same worktree pay twice? Normal Mix and ElixirLS compile into
   `_build/test` and `.elixir_ls/build/test` respectively.
4. Why keep those directories separate? Their compiler options, application build
   state and concurrent writers must not interfere.
5. Why not copy another worktree's entire build? Application artifacts and source
   metadata may describe that other checkout. Dependency-only copying avoids the
   application artifacts but does not remove dependency source metadata.
6. Why do dependency definitions still point to the donor? Their BEAM compile-info
   chunks retain absolute source paths, and ElixirLS uses those paths when they exist.
7. Why does a successful startup build not repair them? Startup forces the project
   application; unchanged copied dependencies are reused without recompilation.
8. What therefore needs fixing? Duplicate preparation and artifact identity, not
   a slow MCP connection or a separate opaque indexing phase. Same-worktree reuse
   addresses the duplication with fewer new identity rules than a global cache.

Further decomposition does not change those two causes.

## Evidence

Fable's earlier probe measured 74.0 s cold readiness and 3.4 s seeded readiness,
plus 0.78 s for its copy. Reading `startup_probe.py` matters: it copied the whole
`_build/test` from the same checkout, not only dependencies from a different
worktree. It polled readiness rather than testing navigation. Its result supports
reuse feasibility, but does not validate Opus's broader cache proposal.

New destination: `/private/tmp/tips-lsp-beta-seed-review`, detached at `fd4e2da`.
Donor: `/private/tmp/tips-lsp-beta-provider`, whose application API had been renamed
by the completed agent workload. Both used the same dependency lock and beta runtime.
Dependencies were copied into independent directories; `lib/tips` was excluded.

| Case | Measured time | Outcome |
| --- | ---: | --- |
| Copy dependency sources from donor | 1.573 s | Separate source tree; no source symlink |
| Copy donor's compiled dependency directories | 0.537 s | No Tips application artifacts copied |
| First ElixirLS start with donor dependencies | 3.147 s to readiness | Tips hover/definition/references worked by 3.700 s; dependency definition pointed to donor |
| Restart with those copied dependencies | 2.674 s to readiness | Wrong dependency path persisted, including a response marked current |
| Compile dependencies with normal Mix in destination | 46.614 s | `MIX_ENV=test`, `+S 4:4`, normal Homebrew Mix, exit 0 |
| Copy destination's own dependency builds | 0.516 s | Independent ElixirLS build; no Tips artifacts copied |
| Start with destination's own dependencies | 2.962 s to readiness | Tips navigation worked by 3.597 s; tested dependency definition resolved locally |

Navigation was requested after readiness in these probes; the times are first
observed answers, not the earliest possible navigation time. Small observation
callbacks captured build messages. These runs are not a randomized paired cold
benchmark. The existing unseeded 63.77–74.0 s results are from other runs.

The dependency request was `Swoosh.Mailer` from `lib/tips/mailer.ex`. The donor-seeded
response returned:

```text
/private/tmp/tips-lsp-beta-provider/deps/swoosh/lib/swoosh/mailer.ex
```

Both donor and copied `Elixir.Swoosh.Mailer.beam` compile-info chunks contain that
path. ElixirLS `location.ex:74–102` reads `module.module_info(:compile)[:source]`
and returns it when it exists. The fallback there concerns core Elixir sources;
it does not relocate dependency paths into the assigned worktree. The definition
locator calls this source-resolution path. This is a code-supported reproduction,
not just a cache-key concern inferred from documentation.

After compiling dependencies in the destination, the same definition request
returned the destination's `deps/swoosh/lib/swoosh/mailer.ex`. Both verification
runs exited with empty stderr, removed owner/socket, and no observed survivors.
The initial probe's process-observation step was sandbox-denied after its responses
were captured; that is preserved separately, not reported as a passed teardown.

## Smallest next implementation candidate

1. During explicit worktree preparation, compile normal project dependencies once
   for the same environment and compatible toolchain used by ElixirLS.
2. When the private ElixirLS build is absent, copy only those dependency build
   directories from that worktree. Never copy the Tips application, a live server's
   state, or shared writable build directories.
3. Perform the copy under existing ownership, stage it before publication, and
   fall back to an ordinary private build if preparation or compatibility fails.
4. Keep ElixirLS's normal dependency checks and forced initial application build.
5. Measure dependency preparation, copy, connection, readiness and useful navigation
   separately. Do not describe this as a three-second worktree creation: this run
   still paid 46.6 s of dependency preparation first.

The observed post-preparation cost was about 3.48 s for copy plus readiness. This
experiment removes the second dependency compilation; it does not eliminate the
first one. It adds no source remapping, binary rewriting, index sharing or daemon.

Before shipping: test configuration/compiler-option changes, failed or interrupted
copy, changed dependency source, native dependency loading, missing seed and repeated
startup. Normal and private compiler compatibility must be explicit. This one
sample does not establish every dependency's navigation or runtime behavior.

Cross-worktree caching is a separate later candidate. Its identity must cover more
than mix.lock: dependency source/path identity, relevant configuration, environment,
target, platform and compiler/bundle options matter. It must also resolve embedded
source paths correctly after donor deletion or mutation. Rebuilding every copied
dependency would repair those paths but surrender most of the intended saving.

## Other performance proposals

The full G1–G6 / D1–D7 disposition is appended to Opus's shared review at
`tmp/review-design-performance/review.md`. Keep the current 250 ms collection window,
five-second feedback and normal incremental builds. Instrument project-reload cost
before bypassing it; mtime-only checks are insufficient. Removing one redundant
Python interpreter is a small independent candidate. Broader test-file exclusions
and readiness-event changes need their own behavior tests.

Raw experiment evidence: `tmp/elixirls-v2/beta-implementation/seed-review/`.
The three-agent results are in [BETA_IMPLEMENTATION.md](BETA_IMPLEMENTATION.md).

## Follow-up proposals: stable shared sources and content-based project reuse

Opus proposed a permanent shared dependency source directory through the standard
`MIX_DEPS_PATH` setting (G1b). This addresses embedded source paths without rewriting
BEAMs. It remains untested. The source review found two concrete Tips boundaries:
LazyHTML's native-build fallback writes under its own `_build/c` directory, and
asset configuration/heroicons still reference `<worktree>/deps`. Test immutable
consumers, native cache misses, Git dependencies, assets and producer deletion.
Keep compiled builds private. The same-worktree seed remains the simpler fallback.

G2b proposes hashes instead of timestamps before reusing loaded Mix project state.
The comparison baseline must describe the successful full reload, not the latest
Lua scan. Reuse Mix's `config_files/0` to help identify inputs; preserve necessary
task, compiler-option and application-state resets. A lockfile-only notification
also needs ElixirLS's existing `additionalWatchedExtensions` support: the current
default extension filter excludes `.lock`. Adding it to the scanner alone would
not trigger the corresponding build.

Both proposals received source review only in this follow-up; no runtime was
changed and no new performance result is claimed. The full why chains, source
locations and proposed boundary tests are under `Codex round 3` in the shared
`tmp/review-design-performance/review.md`. Measure build phases before G2b, and test
the two candidates independently before combining them.
