# Delegate settled work

Delegate work whose goal, scope and solution are already decided.
Examples: fill a template, apply a checklist, run specified commands, collect results or
make a specified change.

Use Haiku in a Claude Code general-purpose agent or Luna in a Codex collaboration agent.
Set effort to high.

Give the worker the inputs, scope, instructions and expected result.
Link existing instructions instead of copying them.
The worker may use scripts.
Use one worker unless independent parts can run in parallel.
Give parallel workers separate write scopes.

Tell the worker to report unexpected inputs, unclear instructions and failures it has no
instructions to resolve.
It must not guess or expand the task.
Ask for the result, supporting evidence and unresolved items.

Inspect the output and evidence.
Check that the required checks ran on the final result.
If they cannot establish completeness, have someone who did not make the changes check
against the goal and source material.
The required reviewer can do this.
A helper's check does not replace a required review.

You make unresolved decisions and decide whether to accept the result.

Read-only work: [Lookup subagents](lookup-subagents.md).
A whole brief: [design-software Step 7](../skills/design-software/SKILL.md#step-7-choose-the-implementer).
