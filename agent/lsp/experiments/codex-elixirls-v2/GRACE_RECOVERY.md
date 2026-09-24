# ElixirLS grace-window recovery experiment

2026-09-24. **Rejected as an eventual-recovery solution.** A small scheduler
patch repairs promptly reported overlaps, but a notification delivered two
seconds after compilation leaves stale compiled behavior and hover after builds
settle, with no automatic recovery observed. The one-second cutoff is the failed
assumption, not the availability of ElixirLS's existing forced-build path.

## Candidate and acceptance contract

Implemented Fable's proposed rule in a private copy of ElixirLS 0.31.1, commit
`256ec7787dc14fa666817199ec6aa5dc64787e37`: record a monotonic timestamp in the
build monitor's DOWN handler and add `recent_build?(state)` to the existing
`force?` option. Any build started within 1000 ms is forced. The patch changes
one source file, adding 14 lines and removing two after formatting.

The accepted source/queue direction did not establish consensus that the cutoff
was correct. This experiment tests that unresolved boundary explicitly.

The server was launched with the existing `ELS_LOCAL=1` and `ELS_INSTALL_PREFIX`
support, using a private installation cache. Installed ElixirLS, active launchers,
the current Neovim adapter, normal agent edits, and the five-second hook are
unchanged. The candidate patch is retained as experimental evidence, not adopted.

The generated fixture has a target function, a compile-time caller caching its
answer, and an unchanged caller used for hover. Equal-length A/B source versions
change documentation and executable behavior. A deliberate 1500 ms compilation
pause makes the overlap reproducible. The target remains unopened; notifications
are injected through the real LSP protocol to control their timing precisely.

Acceptance requires fresh live hover and two passing ExUnit assertions against
ElixirLS's actual build artifacts in a fresh VM. `mix run --no-start --no-compile`
uses `.elixir_ls/build/test`, so the assertion process cannot repair the build.
These acceptance assertions were written and failed on the original server
before the candidate patch was applied.

## Results

| Case | Target / compiled caller | Live hover | Result |
|---|---|---|---|
| Unpatched, A→B during build, prompt notification | A / A | A | Reproduced failure; both assertions fail |
| Patched, same overlap | B / B | B | Pass |
| Patched, notification 300 ms after completion telemetry | B / B | B | Pass |
| Patched, notification 2000 ms after completion telemetry | A / A | A | **Fail; both assertions fail** |
| Patched, B→C during forced recovery | C / C | C | Pass |
| Patched, revert B→A during forced recovery | A / A | A | Pass |
| Patched, ten ordinary stable edits | Final saved value / same | Final value | Pass; all ten builds incremental |

Each overlap case observed five seconds after the expected final build; none
produced an additional build. Ordinary edits used a 1.3-second interval measured
from completion telemetry and a final 1.3-second observation. Every probe server
exited with status zero; a final process-table check found no surviving probe or
candidate launcher process. This is not a repeated lifecycle stress test.

The delayed failure also reproduces the exact bookkeeping mismatch: the manifest
digest matches B on disk, while the target and compile-time caller both return A.
The notification is delayed, not dropped. The source stops changing before the
first build completes. The subsequent incremental build returns `mix_compile_noop`.

Measured fixture build times:

- Ordinary incremental builds: 30–40 ms; two files compiled on every edit.
- Prompt forced recovery: 1554 ms; all three files compiled.
- Recovery after 300 ms notification delay: 1543 ms; all three files compiled.
- Failed recovery after 2000 ms delay: 22 ms; incremental no-op.

The 1500 ms artificial pause dominates recovery time. These numbers do not measure
warm Tips rebuild cost or establish natural notification-delay frequency.

## Root of the failed boundary

1. Why does stale A survive? The next build does no recompilation.
2. Why is that build incremental? Its notification arrives outside the grace period.
3. Why is the source still considered fresh? The manifest already records B's digest.
4. Why does waiting not help? The mismatched artifact/fingerprint persists after
   the grace period expires.
5. Why is extending the period insufficient as a correctness argument? It moves
   the timing boundary without establishing a maximum delivery delay.
6. Why does another ordinary build not necessarily repair it? It can consult the
   same incorrect manifest and make the same no-op decision.
7. Why retain the queue direction? The passing cases demonstrate that its existing
   force path repairs the tested application and its compile-time dependent when
   selected. The unresolved part is deciding when recovery is required.

Do not widen the timeout and label the problem solved. A replacement trigger must
pass the delayed-delivery acceptance test. Retain normal incremental behavior,
qualified semantic results, and the five-second hook while revising that trigger.

## Validation and limitations

- Existing ElixirLS server suite: **77 passed** (`unbuffer mix test test/server_test.exs`).
- Patched source formatting check: passed.
- Warnings-as-errors compilation: **failed** in unchanged upstream code. Test mode
  reports type warnings in `elixir_ls_utils/test/support/modules_with_docs.ex`;
  production mode reports a type warning in `language_server/parser.ex:542`.
  The server still builds and runs, but this is not a clean warnings-as-errors pass.
- `mix credo --strict`: task unavailable in the ElixirLS checkout.
- The first harness attempt pointed `MIX_BUILD_PATH` at the parent of the test
  build and could not load the modules. Its results are excluded. The corrected
  baseline then failed on actual `aa != bb` assertions, not missing modules.
- Initial dependency retrieval could not write the global Hex cache; a private
  cache resolved it. Attempted installation-cache restoration hit an installer
  cleanup error; the ordinary local installer then completed successfully.
- No patched-server crash, path-dependency race, Claude parity, Neovim hook,
  fixture-noise, or full Tips workload test was run in this experiment. The
  controlled timing failure already rejects the candidate's recovery contract.
- The direct protocol tests establish possibility, not frequency in agent work.

## Artifacts and replay

- [Executable probe](grace_recovery_probe.py)
- [Candidate patch — rejected for adoption](elixirls-grace-window.patch)
- [Machine-readable results and validation status](grace-recovery-evidence.json)
- Raw logs, source checkout, fixture BEAMs and failing assertions:
  `/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/grace-recovery/`

The local source checkout is already patched and its isolated launcher built.
Replay with a new output directory:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/grace_recovery_probe.py \
  --server-source tmp/elixirls-v2/grace-recovery/elixir-ls \
  --case late-2000 \
  --output tmp/elixirls-v2/grace-recovery/replay-late-2000
```

Other cases: `overlap`, `late-300`, `recovery-edit`, `revert`, `ordinary`.
Omit `--server-source` to use the installed unpatched server. A failing
acceptance result returns exit status 1 and retains all evidence.
