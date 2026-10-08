# Finish

Read the applicable sections at the retrieval points in the [engineering map](../SKILL.md#when-to-read).

Required behavior and checks remain required; a named verification gap does not
satisfy a requirement.

Inspect the diff and affected callers for missed behavior. Remove additions whose
absence would not break a requirement or make the solution harder to understand,
change or operate. Update affected documentation and delete superseded code, files,
documentation and tests in the same PR.

Run the [required repository checks](../../../../AGENTS.md#checks). Follow the existing
blocker, [PR review](../../../teams/pr-review-record.md) and handoff procedures.

Record durable contracts and decision reasons in the repository documentation that
owns them, linked from the relevant entry point; update it rather than creating
competing instructions. Record task-specific trade-offs, open assumptions and
verification limits in the PR or handoff so later work knows when to revisit them.
