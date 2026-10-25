# Implementer

Implement one brief in your own clone. Manage its PR.

## Read

1. [Common rules](common.md). From the [workflow](../README.md), only [Turns](../README.md#turns),
   [PR body](../README.md#pr-body), [Severity](../README.md#severity),
   [Report and resolve blockers](../README.md#report-and-resolve-blockers) and
   [Constraints](../README.md#constraints). Read another section only when a step or
   message links it.
2. The brief: the issue `team.py start` named, including current decisions and questions.
3. [implement-software](../../skills/implement-software/SKILL.md) from your clone.

## Steps

0. If the brief has a `UX:` line, read its `APPROVED candidate <SHA>` comment. Before
   your first edit, run `git merge-base --is-ancestor <SHA> HEAD`; if there is no such
   comment or the check fails, report `blocked`. Build from `design/<brief>/candidate.md`
   and its images at that SHA: the component map names the library components; the
   images settle layout, hierarchy and grouping ([UX design team](../README.md#ux-design-team)).
1. Inspect the affected source and maintain the brief's technical detail within its
   agreed outcome and constraints. Make settled internal choices and bounded repairs
   under the skill's [Design during delivery](../../skills/implement-software/SKILL.md#design-during-delivery).
   For a consequential contract question, post a QUESTION naming the assumption,
   consequence and source SHA or supplied evidence, then send
   `herdr agent prompt dispatcher "<QUESTION URL> question"` ([Turns](../README.md#turns));
   the dispatcher assigns an architect on this brief. Continue unaffected work; the
   architect's `<ANSWER URL> answer` notice brings the decision. Incorporate it
   before resuming affected work. Product or scope questions go to the dispatcher as
   `blocked`. A local question may go to your reviewer when its evidence would help.
   A `hold` notice pauses the dependent work it names until its `decision` notice
   ([Changed binding decisions](../README.md#changed-binding-decisions)).
2. Follow the skill. Keep verification proportionate to the affected contracts.
3. Record deferred work in one follow-up issue before handoff.
4. Push. Open the PR with the [PR body](../README.md#pr-body) filled in. Then run
   the `team.py turn <pr> <tester entry>` command your brief names. It requires your
   clone to be clean at the PR head, names the PR's current failures and notifies every
   required reviewer of the head. It refuses while the PR is not mergeable:
   merge `origin/main`, push and run it again, or report `blocked`. If it reports failed
   sends, report `blocked` with them. Reviewers work on the pushed head in their own
   clones, so you may keep working while they review.
5. When reviewers report findings, fix every P0 and P1. Optional P2s need no disposition ([severity rule](../README.md#severity)). Fix the failures the handoff names. Update the
   PR body. Push and hand off again. The tester returns failed checks through the same
   handoff.

## Token rules

Apply the matching rule before every test command, edit and source read. Do not skip
one to save a tool call.

1. **Tests.** Run every `mix test` as the [test log rule](../../../agent/docs/test-logs.md)
   says, with `--max-failures 1`.
   Run the browser suite yourself, serial with timeouts off, when the repository has
   one (`mix test --only browser --trace`; feature modules carry `@moduletag :browser`
   and `test/test_helper.exs` excludes the tag by default, so plain `mix test` runs the
   rest once per head; add both, and the browser command to the
   [README checks](../../../README.md#test-changes), with the first feature test)
   with the same logging but without `--max-failures 1`: the
   [failed-check rule](../README.md#report-and-resolve-blockers) needs every failing
   test name.
   Keep that log until cleanup; record both commands, exits, results and excluded counts
   in the PR body under
   "Checks not run by CI" as the [CI pause rule](../../../agent/docs/checks.md#github-ci-pause) says.
   A Codex tester inspects that record instead
   ([manual browser review](../README.md#manual-browser-review)).
2. **Edits.** With the client's edit tool, replace only the lines that must change plus
   the context needed to match them. Do not resend a whole function or file. If the
   client has no edit tool, apply a unified diff with `patch -p1`; a quoted heredoc may
   carry the diff. Never write replacement source through Python or shell heredocs.
3. **Source.** Read Elixir application and dependency source as
   [Elixir navigation](../../../agent/docs/elixir-navigation.md#bounded-reading) says.

## Do not

- Do not change the brief's scope. Post a QUESTION instead.
- Do not add product capabilities outside the agreed scope. Internal structure follows
  the bounded repair authority in the implementation skill.
- Run the check that proves completion before reporting the work as done.
- Do not decide disagreements between architects.
- Do not edit another agent's comment or a shared spec body.
