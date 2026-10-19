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

1. Inspect the affected source and maintain the brief's technical detail within its
   agreed outcome and constraints. Make settled internal choices and bounded repairs
   under the skill's [Design during delivery](../../skills/implement-software/SKILL.md#design-during-delivery).
   For a consequential contract question, post a QUESTION naming the assumption,
   consequence and source SHA or supplied evidence. Notify the dispatcher to assign a
   designer on this brief. Continue unaffected work; incorporate the linked ANSWER
   before resuming affected work. Product or scope questions go to the dispatcher as
   `blocked`. A local question may go to your reviewer when its evidence would help.
2. Follow the skill. Keep verification proportionate to the affected contracts and
   explain changes to an existing test budget in the PR.
3. Record deferred work in one follow-up issue before handoff.
4. Push. Open the PR with the [PR body](../README.md#pr-body) filled in. Then run
   the `team.py turn <pr> <tester entry>` command your brief names. It requires your
   clone to be clean at the PR head, records the PR's failures and notifies every
   required reviewer of the head. It refuses while the PR is not mergeable:
   merge `origin/main`, push and run it again, or report `blocked`. If it reports failed
   sends, report `blocked` with them. Reviewers work on the pushed head in their own
   clones, so you may keep working while they review.
5. When reviewers report findings, fix every P0 and P1. Handle P2s as the [severity rule](../README.md#severity) says. Fix the failures the handoff names. Update the
   PR body. Push and hand off again. The tester returns failed checks through the same
   handoff.

## Token rules

Apply the matching rule before every test command, edit and source read. Do not skip
one to save a tool call.

1. **Tests.** For every `mix test` invocation, including one test, one file and reruns,
   run from your clone's root:
   `mkdir -p tmp && mix test <args> --max-failures 1 > tmp/<name>.log 2>&1; echo "exit=$?"`.
   Use a new `<name>` per run. The printed `exit=` is the result. On `exit=0`, read
   `tail -n 10 tmp/<name>.log` and stop. On any other exit, run
   `grep -n -E 'failure|error|seed|\*\*' tmp/<name>.log | head -n 40`, then
   `sed -n` at most 60 lines around the first failure. Never `cat` or Read the whole log.
   Run the browser suite yourself: `TIPS_BROWSER=1 mix test test/tips_web/features --trace`
   with the same logging but without `--max-failures 1`: the
   [failed-check rule](../README.md#report-and-resolve-blockers) needs every failing
   test name. Plain `mix test` covers the rest, so the unit suite runs once per head.
   Keep that log; name its path, command and `exit=` line in the PR body under "Checks
   not run by CI". A Codex tester verifies your log instead
   ([manual browser review](../README.md#manual-browser-review)).
2. **Edits.** With the client's edit tool, replace only the lines that must change plus
   the context needed to match them. Do not resend a whole function or file. If the
   client has no edit tool, apply a unified diff with `patch -p1`; a quoted heredoc may
   carry the diff. Never write replacement source through Python or shell heredocs.
3. **Application source.** Before displaying an Elixir file whose length you do not
   know, run `wc -l < <file>`. For a file over 300 lines:
   - Run `"$TIPS_DEXTER" query symbols <file>`. It lists every definition with its line.
   - Read one definition at a time: `sed -n <start>,<next start - 1>p <file>`, using the
     line of the definition and the line of the one after it. Independent ranges may go
     in one batch of parallel tool calls; a batch costs one request. For a module attribute,
     alias, struct or `use` line, find it with `rg -n <text> <file>` and read at most
     20 lines around it.
   - Read the whole file only when a named question cannot be answered from those
     ranges, and at most once; after that, ranges only. After an edit, rerun `symbols`
     before using its lines again.
   - If `TIPS_DEXTER` is unset or the command fails, say so once, then use `rg -n` to
     find the line and read ranges. Do not fall back to a whole-file read.
4. **Dependency source.** For any file in `deps/`, regardless of length, never read the
   whole file. From a call site run `"$TIPS_DEXTER" query definition <file> <line>
   <column>`; without a call site run `"$TIPS_DEXTER" lookup Module function --strict`.
   Read only the returned definition with `sed -n`.

## Messages you send

- QUESTION on the brief, to the dispatcher for designer assignment, or to the assigned
  lead. Local questions may go to the existing reviewer.
- `team.py turn <pr> <tester entry>` after each push.
- `blocked` to the dispatcher, as the [blocker procedure](../README.md#report-and-resolve-blockers) says.

## Do not

- Do not change the brief's scope. Post a QUESTION instead.
- Do not add product capabilities outside the agreed scope. Internal structure follows
  the bounded repair authority in the implementation skill.
- Run the check that proves completion before reporting the work as done.
- Do not decide disagreements between designers.
- Do not edit another agent's comment or a shared spec body.
