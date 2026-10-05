---
name: github-comments
description: Load before drafting or editing GitHub comments, reviews or replies. Keep messages concise while preserving decisions, findings and required evidence.
---

# GitHub comments

AGENTS.md Writing applies. Paths below are from the repository root, not the
native skill link. This skill governs writing; posting still requires task
and team authorization.

- Keep routine updates to a short paragraph or a few bullets. Give actionable
  findings and required records enough space; do not omit evidence to meet a quota.
- Distinguish pending checks from passing ones. Report verification gaps and
  limits that linked CI does not establish; omit inventories of passing checks.
- Before posting, remove sentences that repeat linked material or add no decision,
  evidence, required acknowledgment or next action. Do not add a separate summary
  when the review or existing record already says it.

## Reviews and replies

Read `agent/teams/reviews.md` before writing a review; it owns the format and
submission procedure. Put local findings inline; use the body for general issues
and lines outside the diff, with `path:line`.

Explain the required change and why it matters. Mark optional advice `Nit:`,
`Optional:` or `FYI:`.

Fix code where that answers feedback. Reply only when useful to explain a fix,
ask or disagree; explain routine repairs in code and commit messages. An approval
needs no acknowledgment. The reviewer resolves their threads after checking.

## Required records

Preserve the fields required by the active role card: readiness contracts,
contract acknowledgments, decisions, blockers, permission denials and merge
records still need their evidence. Record agreed decisions and dissent, not
interview transcripts. Follow Decisions in `agent/teams/README.md` and the
approval requirements in `agent/teams/reviews.md`.
