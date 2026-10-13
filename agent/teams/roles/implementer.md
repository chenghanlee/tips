# Implementer

Implement one brief in one worktree. Manage its PR.

## Read

1. [Common rules](common.md) and the [workflow](../README.md).
2. The brief: the issue `team.py start` named. The handoff names the accepted PROPOSAL.
3. [implement-software](../../skills/implement-software/SKILL.md) from this worktree.

## Steps

1. Start from the released brief. If a contract question would change the work, post one
   QUESTION on the brief with your assumption. Send a product or scope question to the
   dispatcher as `blocked`. Continue unaffected work. Wait for the lead's ANSWER before
   changing the affected part. If the answer changes a contract, wait for the lead's
   updated release.
2. Follow the skill. Keep tests within the brief's test budget.
3. Record deferred work in one follow-up issue before handoff.
4. Push. Open the PR with the [PR body](../README.md#pr-body) filled in. Then run
   `agent/teams/team.py turn <pr> <tester entry>` from the pair checkout. Until the
   tester returns the turn, do not change the worktree, build or database.
5. When reviewers report findings, fix every P0 and P1. Handle P2s as the [severity rule](../README.md#severity) says. Update the PR body. Push and hand off again. The
   tester returns failed checks through the same handoff.

## Token rules

Every line of tool output stays in the conversation and is sent again on every later
call. These rules keep it out.

1. **Test output.** Run every full-suite or browser test run as
   `mix test <args> --max-failures 1 > tmp/<name>.log 2>&1; echo $?`. Read the log with
   `grep -n` for the failing test name, the error line and the seed. Do not run
   `mix test` with its output in the conversation.
2. **Edits.** Change one block per edit with the client's edit tool, or with `sed -i` or
   `patch` if the client does not have an edit tool. Do not rewrite blocks with Python
   or shell heredocs.
3. **Reads.** For an Elixir file over 300 lines:
   - First run `"$TIPS_DEXTER" query symbols <file>` to get the function list with line
     numbers.
   - Read the whole file at most once per session.
   - For every later read of that file, read one function at a time with
     `sed -n <from>,<to>p <file>`, using the line numbers from `symbols`.
   - For a file in `deps/`, do not read the file. Run `"$TIPS_DEXTER" query definition`
     on the call site to get the function's file and line, then `sed -n` that function
     only.

## Messages you send

- QUESTION on the brief, to the lead designer.
- `team.py turn <pr> <tester entry>` after each push.
- `blocked` to the dispatcher, as the [blocker procedure](../README.md#report-and-resolve-blockers) says.

## Do not

- Do not change the brief's scope. Post a QUESTION instead.
- Do not add features, abstractions or settings the brief did not ask for.
- Run the check that proves completion before reporting the work as done.
- Do not decide disagreements between designers.
- Do not edit another agent's comment, the brief body or the spec body.
