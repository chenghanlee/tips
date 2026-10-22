# Tips

Tips helps developers find and share practical AI techniques with firsthand results.
Rebuilt from scratch since 2026-10-21, one thin vertical slice at a time.

## Purpose

Three gaps, addressed together:

- Useful advice is scattered.
- Advice goes stale as tools change.
- Advice lacks concrete steps a developer can adapt.

## First audience

Developers who use AI for coding, debugging and software workflows. They are the focus
for interviews, seed content and search tests. The site stays open to everyone.

## First scenario

A developer wants a coding agent to make a correct, scoped change without unrelated
edits. The reader:

1. Searches for that problem.
2. Finds a relevant technique.
3. Reads the author's firsthand account and other users' reviews.
4. Tries it in their own workflow.
5. Comes back to describe what they tried and what happened.

Rules:

- Use this scenario to pick seed content and judge search.
- It does not narrow the supported topics.
- Do not present illustrative examples as real firsthand experience.

## Success signals

In priority order:

1. Developers find and try a technique, then report a better coding workflow.
2. Developers find a technique they intend to try.
3. Developers come back for later problems.

Only signal 1 shows a technique worked. Validate through observed trials, interviews
and firsthand reviews.

## Seed content

The founder seeds the first techniques and invites a small group of developers by
personal outreach.

## Principles

- Agile. One epic at a time. One story at a time. The next story is written after the
  user demos the last one.
- Thin vertical slices. A story ships its UI, logic and database change in one issue
  and one PR.
- Reuse over invent. Prefer industry standards, guidelines, libraries and tools to our
  own designs.
- Simplest working solution. Add a part when a story needs it, not before.
- Process. An epic is an issue with the label `epic`; its stories are sub-issues. The
  story issue is the brief the agents work from: it carries the roster lines, has one
  branch `task/<issue>` and one PR that says "Closes #<issue>", merged
  with a merge commit after pair review. Project 15 Done means merged; the user tries
  each story before the next one is written. Project 15 holds status only.

## Where things live

| What | Where |
|---|---|
| Status and planning | [GitHub Project 15](https://github.com/users/chenghanlee/projects/15) |
| Story scope and acceptance | GitHub issues |
| Design facts and decisions | [docs/design](docs/design/README.md) |
| Engineering rules | [AGENTS.md](AGENTS.md) |
