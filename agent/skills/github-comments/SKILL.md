---
name: github-comments
description: Write concise GitHub issue comments, PR comments, reviews and replies. Load before drafting or editing these messages.
---

# GitHub comments

Write only what the next reader needs to act or audit. This skill governs writing;
posting still requires authorization under the task and team rules.

- Lead with the result, decision or blocker and next action, if any.
- State each new fact once. Link existing evidence, contracts, diffs and earlier
  decisions instead of retelling them.
- Keep routine updates to a short paragraph or a few bullets. Use more space for
  an actionable finding or a required contract; do not omit evidence to meet a quota.
- Omit process narration, unchanged-code walkthroughs, passing-check inventories,
  ceremonial headings and acknowledgments that the workflow does not require.
- Keep the relevant revision, findings, verification gaps and limits. Report what
  linked CI does not establish; distinguish pending checks from passing ones.
- Before posting, remove any sentence that repeats linked material or adds no
  decision, evidence, required acknowledgment or next action. Do not post a separate
  summary when the review or existing record already says it.

## Reviews and replies

Submit one review per pass on the exact head using the team's
[review procedure](../../teams/reviews.md). Put local findings inline; use the body
for general issues and lines outside the diff, with `path:line`.

Explain the required change and why it matters. Mark optional advice `Nit:`,
`Optional:` or `FYI:`. Do not repeat the diff, contract or passing checks.

Approval starts with `LGTM` alone, then role and session. A tech lead adds the
tester's approving review link on line three. Add scope or limits only when
needed, including pending checks. Other reviews start with role and session.

Fix code where that answers feedback. Reply only when useful to explain a fix,
ask or disagree; explain routine repairs in code and commit messages. An approval
needs no acknowledgment. The reviewer resolves their threads after checking.

## Required records

Preserve the fields required by the active role card: readiness contracts,
contract acknowledgments, decisions, blockers, permission denials and merge
records still need their evidence. Link design sections instead of copying them.
Record agreed decisions and dissent, not interview transcripts. The approving
review closes the decision record; no separate closing note.
