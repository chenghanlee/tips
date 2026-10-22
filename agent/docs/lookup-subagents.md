# Lookup subagents

When your client offers a lookup subagent, use it for bounded evidence gathering:
locating unfamiliar code, collecting related facts across files, comparing conventions,
or answering a factual question from several sources. Claude Code: the `Explore` agent
with Haiku. Codex: a collaboration agent with Luna, prompted to search and read only.
Both at high effort. Give it the question, the worktree to search and the scope. Ask for
a concise answer, each supporting `path:line` with a short quote, and what it left out;
for an "all", "only" or "none" answer, ask for the search scope and exclusions.

Before relying on the result in a change or review, read the cited source and enough
context to verify it, and check completeness when the decision depends on it. Keep known
short reads, literal lookups and Dexter lookups ([Elixir navigation](elixir-navigation.md))
inline. The subagent gathers and explains evidence; you own design and implementation
decisions, review findings and verdicts. It does not edit and does not replace an
independent reviewer.
