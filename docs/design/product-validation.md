# Product validation

How the first developer trials test the Tips product hypothesis. The system requirements these trials rely on are in the [backend design](backend-design.md#business-requirements).

## Hypothesis

Tips addresses three gaps together:

- Useful advice is scattered.
- Advice becomes outdated as tools change.
- Advice often lacks concrete steps a developer can adapt.

Whether advice generalizes is not the primary gap. Validate the hypothesis with the first audience.

## First audience

- Developers who use AI for coding, debugging and software workflows.
- They are the focus for the first user interviews, seed content and end-to-end search tests.
- This is a validation focus, not an access restriction. The site stays open to other audiences.
- Evaluate discovery quality with developer tasks and firsthand results, not generic sample queries alone.

## First scenario

A developer wants a coding agent to implement a correct, scoped change without unrelated edits. The reader:

1. Searches for that problem.
2. Finds a relevant technique.
3. Inspects the author's firsthand account and other users' reviews.
4. Tries it in their own workflow.
5. Can return to describe what they tried and what happened.

Rules:

- Use this scenario to select seed content and evaluate search.
- It does not narrow the supported topics.
- Correctness and scope are outcomes to assess in user testing. A Helpful vote does not establish them.
- Do not present illustrative seed examples as real firsthand experience.

## Success signals

In priority order:

1. Developers find and try a technique, then describe an improvement in their coding workflow.
2. Developers find an actionable technique they intend to try.
3. Developers return to Tips for later coding problems.

Signals 2 and 3 do not show that a technique improved a workflow. Start validation through observed trials, interviews and existing firsthand reviews.

## Seed content and recruiting

- Seed the trials with the founder's firsthand techniques and contributions from a small invited group of developers.
- The founder recruits contributors, organizes trials and contributes.
- Invitations are personal outreach only.
