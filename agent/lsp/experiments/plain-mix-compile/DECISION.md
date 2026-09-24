# Decision: retain Neovim + ElixirLS; archive foreground Mix

2026-09-25. User decision after the foreground Mix experiment and navigation
capability comparison.

## Selected direction

Continue with the saved Neovim + ElixirLS integration, including hover,
definitions, references, qualified compiler feedback, and the tested worktree
synchronization and lifecycle behavior.

Retain `experiment/elixirls-codex-v2` and its worktree. The implementation savepoint
is `f878459640028a7c607afab4a523c27a6304ceb9`, also identified by
`savepoint/neovim-elixirls-hook-2026-09-25`. The bundle integrity check passed again
when archiving the foreground alternative. Selection does not remove its documented
limitations or constitute a production rollout. Active client configuration was
not changed by this archival operation.

Archive `experiment/plain-mix-compile` without merging it to main. Keep its code,
research, evidence, and replay probes in Git; remove its disposable worktrees after
verifying the commit. Binary toolchains, build caches, dependency copies and copied
upstream source trees are disposable. Pinned source URLs/hashes and the private
compiler build recipe remain available.

## Findings worth retaining

- Foreground compilation is a viable, faster compiler-feedback path in the
  measured Tips cases. The complete patched hook took 0.84–0.94 seconds for warm
  edit/error/repair feedback, and about 0.07 seconds for unchanged tools.
- Separate cold preparation took 49.1 seconds with dependencies already fetched.
- Waiting longer delivered the eight-second compiler error. Repeated five-second
  cancellation was a policy-induced progress failure, not an inherent Mix limit.
- Stock Mix 1.20.4 produced stale target and compile-time caller values after
  sequential equal-size writes within one timestamp second. Both compile commands
  succeeded; fresh-VM assertions exposed the stale artifacts.
- The existing targeted Mix patch passed this case, preserved-metadata edits,
  external-resource changes, and retained-path recovery after another write during
  compilation. It adds 10 lines and removes 3 across two Mix files. It extends
  invalidation through `--force-path`; it is not a general compiler rewrite.
- The complete foreground hook is 246 lines, separate from the small compiler
  patch. Observation, process ownership, timeout cleanup and feedback delivery
  remain integration responsibilities.
- Foreground Mix does not refresh ElixirLS's separate live state. Replacing the
  feedback producer would not establish equivalent navigation behavior.
- The measured stock command (0.65–0.74 seconds), complete patched hook
  (0.84–0.94 seconds), and earlier Neovim cohort (1.43–2.88 seconds) were not a
  paired performance benchmark. No production failure rate was measured.

The archived [analysis](ANALYSIS.md) contains the why chains and code trace. The
[prototype report](README.md) and [structured evidence](foreground-evidence.json)
record acceptance and limitations. Actual model-driven foreground hook receipt
and a new three-agent foreground Tips cohort were not tested.

## Navigation research

Standard Mix/Elixir can support useful explicit-symbol lookup, but `mix compile`
does not expose a complete navigation service:

- `Code.fetch_docs/1` retrieves compiled documentation and signatures.
- IEx `open/1` locates named module/function source; Elixir 1.20 `source/1` prints it.
- `mix xref graph` reports file dependencies; `mix xref trace` compiles a selected
  file to report dependency occurrences and lines. Neither is a complete
  project-wide symbol-reference service. The older `Mix.Tasks.Xref.calls/1` API is
  deprecated in favor of compilation tracers.
- Resolving a file/line/column requires handling aliases, imports, scope, macros
  and incomplete code. ElixirSense offers existing analysis building blocks.
- Current ElixirLS documentation describes native MCP tools for documentation
  and definitions. The listed tools do not establish full references parity.
  Compatibility with our pinned setup was not tested. This is research retained
  for future use, not a selected replacement for the working Neovim integration.

Our Mix patch adds no navigation features. Building a custom reference index or
cursor-resolution adapter was not approved or implemented during this experiment.

References inspected during the investigation:

- [Code.fetch_docs/1](https://elixir.hexdocs.pm/Code.html#fetch_docs/1)
- [IEx source/1](https://iex.hexdocs.pm/IEx.Helpers.html#source/1)
- [Mix xref](https://mix.hexdocs.pm/Mix.Tasks.Xref.html)
- [ElixirSense](https://github.com/elixir-lsp/elixir_sense)
- [ElixirLS native MCP](https://github.com/elixir-lsp/elixir-ls#mcp-model-context-protocol-server)

## Evidence preservation

The [archive index](evidence/archive-index.json) records byte-identical copies of
selected logs, JSON results and acceptance scripts from the final and preceding
runs. It also preserves Fable's original release review and the independent older
overlap counterexample. That review is a historical input; several of its claims
were challenged or corrected by the later analysis, not adopted as conclusions.

Archived logs may mention now-deleted absolute worktree paths. Use the archive
index to locate their copies. Prior Neovim reports and patches are inherited from
the savepoint in this branch's history. No application changes or active hooks
are installed from this archive.
