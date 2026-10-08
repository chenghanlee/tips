# Design and change

Read the applicable sections at the retrieval points in the [engineering map](../SKILL.md#when-to-read).

## Contents

- [Scope the task](#scope-the-task)
- [Build the simplest working solution](#build-the-simplest-working-solution)
- [Reuse existing mechanisms and follow conventions](#reuse-existing-mechanisms-and-follow-conventions)
- [Trace the affected contract](#trace-the-affected-contract)
- [Repair and refactor](#repair-and-refactor)

## Scope the task

Investigate until remaining uncertainty would not change the approach or required
verification. Spend more where mistakes could lose data, cause external effects or
be expensive to undo.

Identify the acceptance scenarios and scope before investigating. Follow task links
and repository entry points to the authoritative requirements, affected contracts
and relevant decisions; read what resolves the current question. Resolve routine
choices from the task, existing decisions and repository conventions. When
alternatives satisfy the same requirements, choose the simplest without asking.
Ask through the existing workflow only when an unresolved ambiguity changes what
counts as correct behavior; continue independent work while awaiting the answer
when that workflow permits it.
Do not add adjacent capabilities.

## Build the simplest working solution

Build the simplest design that delivers the required behavior through the complete
affected flow, including required failure handling. A shorter implementation that
leaves required behavior unfinished is not simpler to maintain. Among complete
solutions, prefer fewer interacting parts, clearer ownership and less coordination;
prefer the user's experience over reducing code.

Add an abstraction, dependency, process, configuration option or stored state only
when you can name the current requirement it serves and why the simpler approach
is insufficient. Do not build for hypothetical scale, reuse or compatibility.

## Reuse existing mechanisms and follow conventions

Before building a custom mechanism, check existing code, built-in features, locked
dependencies and commonly used libraries or tools. Prefer stable interfaces with
behavior you can establish from documentation, source or a focused probe. Include verification,
workarounds and future fixes in the integration and maintenance cost. Build your own
only when none meets the requirements or that total cost exceeds building and
maintaining your own. When you build your own, say what you checked and why in the PR.

Before copying a nearby pattern, check it against the current contract and
conventions. Repetition in the repository does not establish that a pattern is
correct.

When the design depends on a dependency's behavior, verify the specific guarantee
at the installed version and configuration. Link the supporting source in the PR.
Similar names or examples do not establish equivalent behavior.

Follow applicable standards and language and framework idioms. Explain deviations
in the PR. Use Ecto's query, changeset and migration DSLs; use raw SQL or `fragment`
only for what they cannot express, and bind runtime values as parameters.

## Trace the affected contract

**When changing behavior or a function's return shape:** identify the required
outcome and what must remain true. Find affected callers using the repository's
navigation rules, and check the consequences through to the final state and effects.
A correct handler result alone does not establish a correct outcome.

**When adding a dependency between modules or domains:** respect documented
ownership and dependency boundaries while choosing the simplest local
implementation. A new feature alone does not justify a new layer or framework.

**When changing a shared rule, stored fact or runtime state representation:** find
its other representations.
Limits, patterns, enums, labels, messages and filters can appear in constraints,
migrations, helper text, documentation, fixtures and other runtimes. Copies of one
rule may look different.

For that rule or fact, keep one authoritative source. Derive duplicate state rather
than storing copies that can disagree; keep independent facts separate. When stored
copies are necessary, define how they stay consistent. Update
each representation affected by the requirement. Consolidate only when it simplifies
this task or removes a concrete inconsistency, and that gain justifies the coupling
and verification cost. Historical migrations are evidence to inspect, not
automatically files to rewrite.

**When refactoring:** preserve existing observable behavior except for changes the
task explicitly requires. If that behavior conflicts with a requirement, make the
conflict explicit rather than silently changing the contract.

## Repair and refactor

**When a result contradicts expectations, or a bug or review finding exposes a
defect:** identify the failed assumption before adding another condition. Check
other sites and transitions that depend on it, and repair those that share the
defect. Verify the whole affected contract, including behavior the reported failure
did not exercise.

**When this task reveals repeated violations of one consequential invariant:** use
an existing enforcement point where it covers the affected paths, fix the remaining
violations and keep checks at each trust boundary. Add custom enforcement only
within the task's scope and when preventing recurrence justifies its execution and
maintenance cost; check the invariant itself and make failures name the rule and
the correction.

**When considering a refactor:** proceed only if the task requires it or the current
implementation reveals an ownership, interface or state problem that materially
complicates the required behavior or its verification. Name that problem and keep
the revision within the affected flow. Inconsistency elsewhere or hypothetical reuse does not justify
expanding the task. Preserve required behavior and verify each increment. Effort
already spent is not a reason to retain an approach. Stop when the named problem is
resolved and required verification passes.
