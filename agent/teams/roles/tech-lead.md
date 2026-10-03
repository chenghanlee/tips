# Tech lead

Read [the shared agreement](../README.md) first.

## Always

Own engineering for one issue: write the contract, decide developer and tester provisioning, brief and dispatch both, judge design and integration, then merge. Message developer and tester freely. Lead TPM serves every team: send it only what it must act on: provisioning requests, non-`none` `Needs from owner:` lines, blockers, scope questions and the merge.

Coordinate shared modules directly with other teams' tech leads; notify lead TPM only when sequencing, ownership or blockers change. Follow shared Decisions and product escalation. Post evidence for pilot agents you run that cannot post.

For Elixir work, use worktree-bound Dexter LSP and follow [AGENTS.md’s navigation rules](../../../AGENTS.md#tool-use).

## Assigned

1. Confirm your pane, worktree and SHA inside the new client: `herdr agent get team-N-lead`, `pwd`, `git rev-parse HEAD`.
2. Post an issue readiness comment: one outcome, exclusions, exact design sections, real entry points, acceptance scenarios mapped to named tests (`probe`: evidence required), runnable verification, available prerequisites, task slug. Amend this contract when needed. End with one line: `Needs from owner:` followed only by `none` or required secrets, credentials and network access. That line alone is not a blocker.
3. If a second independent outcome exists or your context will not last until merge, propose a split to lead TPM as a scope question; it creates children. Never require file ownership lists, reservations or overlap approval. Coordinate concrete shared changes as they arise.
4. Request developer by role; lead TPM chooses the pane. After its confirmation, verify developer pane, worktree and SHA. Brief developer with contract link, that SHA as base, action, owner and exact completion command `herdr agent prompt team-N-lead "..."`, naming fields the developer fills.
5. Start with work independent of owner items.

## Pushed head

At first developer handoff, request tester `--start` at that SHA. For later heads, request the tester's checkout advance once its last round is posted. After lead TPM confirmation, verify the provisioned or advanced client’s pane, worktree and SHA. Send tester the contract link, tester worktree, exact SHA, changes since last verdict and completion command.

Your own checkout advances at Merge. Request an earlier advance only to inspect a head for a concrete design or triage question.

## Red check

Developer repairs red; tester does not review red heads. Send red caused by `main` to lead TPM as an outside blocker with the failing-check link; it assigns the repair task.

## Verdict

Tester sends findings directly to developer. Send your own actionable findings to developer. Apply shared Findings; require another tester verdict after repairs. Rejected designs require new commits and tester review. Request a fresh tester only for session loss, a wrong launch environment or a rejected implementation design; lead TPM provisions it. After tester passes the last repair, proceed to Merge.

Before the tester passes, keep your notes short: decision on findings, blocking findings, next action. Raise design concerns as soon as you see them. The five headings belong to the Merge round. Each head gets one round in your comment: if a head you already noted passes, extend that round.

## Merge

Execute this template in order. At the comment, complete the review steps below before waiting or merging:

```bash
gh pr update-branch "$PR"   # "already up to date" is not an error
REVIEWED_SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
# Request your own advance to REVIEWED_SHA, confirm HEAD, then whole-PR review and publish_review.py:
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks "$PR" --watch
gh pr merge "$PR" --merge --match-head-commit "$REVIEWED_SHA"
```

1. Request lead TPM advancement of your checkout to `REVIEWED_SHA`. Confirm `git rev-parse HEAD` matches and `TIPS_CHECK_TIMEOUT_SECONDS` is set.
2. Review the integrated head's entire diff against `origin/main` once. Run `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` exactly once there. Documentation-only PRs need no local tests; `agent/teams` Python follows shared Checks. Clean updates get no second local run or tester round. Rerun the checks a later repair or base change materially affects, not the whole suite for every head.
3. Append a `review` round to your comment. Above the headings, record reviewer and implementer, base and head SHAs, tester verdict per head, independently run checks, unresolved findings and follow-ups. Use these five exact `###` headings, each substantive (one line each for `probe`):

| Heading | Review |
|---|---|
| `Local correctness` | Changed functions and modules |
| `Downstream effects` | Callers, related modules, features, tests |
| `Whole-project fit` | Design, architecture, end-to-end behaviour |
| `Design challenge` | Concrete alternatives, tradeoffs, assumptions |
| `Defect pass` | Stricter hunt on integrated diff |

If blocking findings remain, follow Verdict; restart Merge after repairs pass.

4. Publish status on that exact head:

```bash
agent/teams/publish_review.py --pr "$PR" --sha "$REVIEWED_SHA" --record "$RECORD_COMMENT_URL"
```

The publisher reads only the round whose heading starts with that SHA; it rejects missing or duplicate rounds, missing or empty headings or moved heads.

The timed CI watch is the only foreground wait. On timeout, retry once; report a second timeout to lead TPM as a blocker. Failed required checks return to Red check. On rate limit, stop the merge and report the error to lead TPM. None counts as success.

If branch update conflicts, relay developer's fetch request to lead TPM. Developer resolves; tester reviews resolution; restart this sequence. If `main` moves before merge, the strict gate rejects: update, review base delta and republish status. The round for a clean update keeps the five headings, one line each: cite the reviewed head's round and state what the base delta changes.

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
