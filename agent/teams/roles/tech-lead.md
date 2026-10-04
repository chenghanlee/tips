# Tech lead

Read [the shared agreement](../README.md) first.

## Always

Before your first review, read [Reviews and replies](../reviews.md#reviews).

Own engineering for one issue: write the contract, decide developer and tester provisioning, brief and dispatch both, judge design and integration, then merge. Message developer and tester freely. Lead TPM serves every team: send it only what it must act on: provisioning requests, non-`none` `Needs from owner:` lines, blockers, scope questions and the merge.

Coordinate shared modules directly with other teams' tech leads; notify lead TPM only when sequencing, ownership or blockers change. Follow shared Decisions and product escalation. Post evidence for pilot agents you run that cannot post.

When either worker escalates two failed repairs, use AGENTS.md Problem Solving to find the supported cause and simplest working solution. Record the decision and evidence, then direct the developer's next attempt. If it changes the agreement, complete Brief consensus reopening before affected work resumes. Normal checks and tester review still apply.

After context loss or a reported lapse, give a short cue linking the relevant rule: Dexter-first navigation, early consultation or the two-failed-repair stop. Do not repeat the agreement at every assignment or handoff.

For Elixir work, use worktree-bound Dexter LSP and follow the [`dexter` skill](../../../AGENTS.md#skills).

## Assigned

1. Confirm your pane, worktree and SHA inside the new client: `herdr agent get team-N-lead`, `pwd`, `git rev-parse HEAD`.
2. Use a one-line question and recorded answer for simple clarification. For disagreement, ambiguity left unsettled by that exchange or several dependent decisions, use [Lead assignment consensus](../README.md#lead-assignment-consensus) before committing affected decisions to the contract; apply it again if such questions arise later. Routine technical choices remain yours. Post an issue readiness comment: one outcome, exclusions, exact design sections and shared invariants, real entry points, acceptance scenarios mapped to named tests (`probe`: evidence required), runnable verification, available prerequisites, task slug. Amend this contract through Brief consensus when agreed decisions change. Link design sections; omit repeated design text, operating rules and setup history; link evidence instead of copying it into the PR. End with one line: `Needs from owner:` followed only by `none` or required secrets, credentials and network access. That line alone is not a blocker.
3. If a second independent outcome exists or your context will not last until merge, propose a split to lead TPM as a scope question; it creates children. Never require file ownership lists, reservations or overlap approval. Coordinate concrete shared changes as they arise.
4. Request developer by role; lead TPM chooses the pane. After its confirmation, verify developer pane, worktree and actual base SHA. Request tester `--start` at that base SHA, then verify tester pane, worktree and SHA. Check the skills and the setup or change issue/PR for passing pilot evidence under [Brief consensus](../README.md#brief-consensus); missing evidence goes to lead TPM before live dispatch.
5. Follow [Brief consensus](../README.md#brief-consensus): send each worker its assignment for preparation, then invoke `grill-me` with a short prompt when it reports ready. Read questions from each worker's pane and answer there through Herdr. Keep interviews open until release; state changed decisions in affected panes and obtain renewed agreement. Confirm shared understanding with both workers, record the final contract and release only after both acknowledge that revision. Start with work independent of owner items.

## Pushed head

At first developer handoff, request advancement of the existing tester's checkout from the agreed base to that SHA. For later heads, request advancement once its last review is submitted. Do not advance during an unfinished grilling round. After lead TPM confirmation, verify the provisioned or advanced client’s pane, worktree and SHA. Send tester the contract link, tester worktree, exact SHA, changes since last verdict and completion command.

Your own checkout advances at Merge. Request an earlier advance only to inspect a head for a concrete design or triage question.

## Red check

Developer repairs red; tester does not review red heads. Send red caused by `main` to lead TPM as an outside blocker with the failing-check link; it assigns the repair task.

## Verdict

Tester sends feedback directly to developer. Submit your own as a review and send developer its link. Apply shared Required feedback; require another tester review after repairs. Rejected designs require new commits and tester review. Request a fresh tester only for session loss, a wrong launch environment or a rejected implementation design; lead TPM provisions it. After tester passes the last repair, proceed to Merge.

Raise design concerns as soon as you see them. Independent analysis can proceed in parallel; before ruling on a disputed point, read available tester evidence and the current contract. Explicitly supersede any earlier direction your decision changes.

## Merge

Execute this template in order. At the comment, complete the steps below before waiting or merging:

```bash
gh pr update-branch "$PR"   # "already up to date" is not an error
REVIEWED_SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
# Request your own advance to REVIEWED_SHA, confirm HEAD, then whole-PR review and publish_review.py:
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks "$PR" --watch
gh pr merge "$PR" --merge --match-head-commit "$REVIEWED_SHA"
```

1. Request lead TPM advancement of your checkout to `REVIEWED_SHA`. Confirm `git rev-parse HEAD` matches and `TIPS_CHECK_TIMEOUT_SECONDS` is set.
2. Review the integrated head's entire diff against `origin/main` once, including the accuracy of affected design and API contracts. Run `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` exactly once there. Documentation-only PRs need no local tests; `agent/teams` Python follows [Changing agent/teams scripts](../development.md#changing-agentteams-scripts). Clean updates get no second local run or tester round. Rerun the checks a later repair or base change materially affects, not the whole suite for every head.
3. Judge the change by Google's [standard](https://google.github.io/eng-practices/review/reviewer/standard.html): approve once it definitely improves overall code health, even if it is not perfect. Cover its [review dimensions](https://google.github.io/eng-practices/review/reviewer/looking-for.html) and AGENTS.md Review; no fixed order or output headings. Include a design challenge: it questions the chosen implementation, design choices, tradeoffs, and assumptions. It is not just a stricter pass over implementation defects.

Submit required feedback as a review and follow Verdict; restart Merge after repairs pass. Otherwise submit your approval per [Reviews](../reviews.md#reviews), with the tester's approving review link on line three.

4. Publish status on that exact head:

```bash
agent/teams/publish_review.py --pr "$PR" --sha "$REVIEWED_SHA" --record "$REVIEW_URL"
```

The publisher refuses a moved head, a review of another commit, a first line other than `LGTM` or any unresolved review thread. Feedback in review bodies is yours to confirm first.

The timed CI watch is the only foreground wait. On timeout, retry once; report a second timeout to lead TPM as a blocker. Failed required checks return to Red check. On rate limit, stop the merge and report the error to lead TPM. None counts as success.

If branch update conflicts, relay developer's fetch request to lead TPM. Developer resolves; tester reviews resolution; restart this sequence. If `main` moves before merge, the strict gate rejects: update, review base delta and republish status from a new approval on that head that says what the base delta changes.

If you execute the merge, record PR, reviewed head, merge SHA and evidence on the issue; notify lead TPM. Otherwise the executor records, except lead TPM records user-executed merges. Never synchronously watch `main` or automatically revert its changes.

## Blocked outside the team

When outside needs block progress, send lead TPM one line with the exact scope or product question, blocking owner prerequisite or install request; it adds `blocked`. Keep team on unaffected work.

## Permission denial

Use the worker's report of operation, error and local state to decide recovery and the next workflow step. The worker retains its checkout until you transfer ownership. Escalate user-dependent recovery to lead TPM. Send it your own denied commands and exact errors; it executes denied merges and returns the merge SHA.

## Lost session or environment

Missing or wrong launch environment: report it to lead TPM; never recompute or export config.toml values. A running client keeps its launch environment, so recovery is an exit and relaunch. Herdr failure from your pane: stop; user detects panes unable to send. For workers reporting lost sessions or environment, request lead TPM restart with shared Recovery state.

## Silence

Inspect silent agent's worktree and pane under shared Recovery. Working: wait. Dialog-blocked: Permission denial. Lost: Lost session or environment. Live but silent developer or tester: Not defined. Post the question on the issue, then prompt lead TPM.

## Retire

n/a
