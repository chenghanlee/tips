# Agent teams

This is the operating agreement for the agents that build Tips. Read your role card, then the shared rules. [AGENTS.md](../../AGENTS.md) governs engineering. GitHub issues and PRs hold requirements, decisions, review history and evidence. [config.toml](config.toml) owns agent settings; do not repeat its defaults in commands or prose. Humans set the machine up once with [SETUP.md](SETUP.md).

Names in code map to roles as follows.

| Role | Agent name | Helper flag |
|---|---|---|
| Lead TPM | `lead-tpm` | n/a |
| Team TPM | `team-N-tpm` | n/a |
| Tech lead | `team-N-lead` | `--role lead`, plus `--ui` for the `ui` lead |
| Developer | `team-N-dev` | `--role dev` |
| Tester | `team-N-test` | `--role test` |

## Events

Every role card has one cell per event, in this order. A cell that reads `n/a` means the event cannot reach that role. A cell that reads "Not defined" means nobody has written the rule yet: post the question on the issue, then prompt the tech lead (a tech lead prompts its team TPM).

1. **Always**: duties that hold at every moment.
2. **Assigned**: an issue, brief, SHA or request arrives in your pane.
3. **Pushed head**: a new SHA exists on the PR branch.
4. **Red check**: a required check failed on a head.
5. **Verdict**: a tester or tech lead round is complete.
6. **Merge**: the PR is ready to integrate, or has merged.
7. **Blocked outside the team**: progress needs the user or another team: secrets, credentials, network, installs, purchases, scope.
8. **Permission denial**: a tool or client refused an action.
9. **Lost session or environment**: a client, worktree or launch environment is missing or wrong.
10. **Silence**: a message got no reply, or failed to send.
11. **Retire**: the issue merged and the team's resources are released.

## Shared rules

**Handoff.** A handoff has two steps: record durable evidence on GitHub, then run `herdr agent prompt` to deliver its link to the recipient. A GitHub comment or a final chat response does not wake another pane. Before ending the turn, verify the Herdr command succeeded; if it failed, report the error and do not claim delivery. A handoff is one line: evidence link, SHA, action and owner; link the existing contract instead of copying it. Every dispatch names the exact recipient and the exact command to run on completion or a blocker; "reply to the lead" alone is insufficient. Questions between developer, tester and tech lead may be freeform; a question about code carries a pushed SHA so the reader looks at real state in its own worktree. Example, with the real team number and evidence filled in:

```bash
herdr agent prompt "team-$N-lead" "$EVIDENCE_URL SHA=$SHA; action=dispatch tester; owner=team-$N-lead"
```

**Waiting.** Herdr is the event bus. Send the prompt, finish any work that does not depend on the answer, and end the turn; the reply arrives as a new prompt. No `sleep`, polling loop, monitor, cron, hook or `--wait`. The one exception is the tech lead's timed CI wait before merge.

**Decisions.** A decision is durable only on GitHub. Whoever decides posts it on the issue or PR before the next step: the tech lead for engineering, the team TPM for project state. The asker links that post in its next handoff. The approving review round is the closing record; decisions made in chat that are not already in PR threads go in its body. No separate closing note.

**Commands.** Run lifecycle and messaging commands directly and keep their stdout, stderr and exit status; do not pipe them through `tail` or ad hoc JSON formatters. Parse Herdr JSON only when a later step needs a returned field, under `result`. A failed formatter is not evidence that a message was undelivered: inspect once before resending. A successful send confirms submission, not completion.

**Git.** `main` is protected. Work on short-lived `task/<issue>-<slug>` branches in worktrees under `.worktrees/`; keep the slug when an issue is renamed. While any team is live the main checkout is read-only for source changes: never switch its branch, edit, commit or run tests there, because running clients and the lifecycle scripts are rooted at it. Repository administration such as fetch and worktree creation runs from main, by the team TPM, or by the lead TPM for `team.py stop`. The developer owns its task worktree; the tester and tech lead have separate detached review worktrees; no agent edits another's checkout. Open a draft PR early. Commit cohesive changes and run relevant checks before pushing. Unpushed commits may be reorganized; published commits are fixed. Never force-push or push implementation to `main`. Repository rules block force pushes on `task/**`, require merge commits, strict up-to-date branches, resolved conversations and the `checks`, `release` and `tips/independent-review` contexts, and delete merged remote heads. That gate is an interlock, not credential isolation. A documentation-only PR needs no local test run; the required CI still runs.

**Issue state.** Issues and PRs are the source of truth. Add `active` when assigned. Add `blocked` when progress needs outside action, with the prerequisite, responsible role and next action in a comment; a waiting dependency is not automatically a user blocker. Remove stale labels. Do not mirror a workflow state machine into Project fields or keep a separate status document. An issue closes only when its required result is integrated and evidenced: partial work uses `Refs #number`, a completing PR uses `Closes #number`. Child issues created during the run count toward the goal. Milestone gates require end-to-end evidence on one integrated revision; closing a package requires its mandatory children and package acceptance evidence. Issues labelled `ui` get the `roles.lead_ui` tech lead, launched with `--ui`; developer and tester settings do not change. Issues labelled `probe` deliver evidence, not a code path: the tester passes once, the review round keeps its five headings at one line each, and probe code is disposable.

**One comment per role.** The developer, tester and tech lead each keep one PR comment and edit it in place, adding a `## <short SHA> <outcome>` round per reviewed head, newest last, with `###` headings inside a round. A handoff links that comment and names the SHA. No new comment per round.

**Independence.** Nobody reviews or merges their own implementation. The tester may ask the developer anything, but its verdict cites code, tests and evidence, never the developer's explanation, because the common GitHub identity cannot mechanically prove reviewer independence. The tech lead decides technical disputes with evidence. Scope or product questions go tech lead, team TPM, lead TPM, user. Routine technical choices belong to the responsible role.

**Findings.** P0 is critical exposure, irreversible loss or inability to operate. P1 is broken required behaviour, an authorization or consistency defect, or missing evidence needed to integrate safely. P2 and P3 are lower-impact defects or improvements; record follow-up issues when deferred. Do not downgrade findings to pass. Required acceptance failures block completion regardless of severity. Repeated failed repairs require root-cause analysis, not more blind attempts.

**Recovery.** For a permission blocker, preserve the work and report the failed operation, exact error and local state to the tech lead; do not route around the denial through another application or a remote-only commit. For context recovery, keep the issue and branch open and record base and head SHAs, working-tree cleanliness, committed and uncommitted work, unresolved findings, failed or unrun checks and the next action. Transfer ownership explicitly before another writer starts. Never reset or stash someone else's work. Inspect Git and pane evidence before reassigning an unresponsive client.

**Environment.** The helper exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV`, `TIPS_CHECK_TIMEOUT_SECONDS` and `TIPS_PROVIDER_ENV_FILE` to the coding process and links the main checkout's `.agents/skills` into each worktree. Leave those computed values in place for tests, including Wallaby. Provider settings are read by path from the main checkout's `.env`, so no secret is ever written into a worktree. Check with `env | grep -E '^(PGPORT|MIX_ENV|TIPS_)'`; macOS `printenv` prints only its first named variable. Startup reports client launched, not index ready: Expert indexes in the background, and nobody adds a compile gate or a probe LSP; see the [LSP guide](../lsp/README.md). Agents propose defaults and use synthetic fixtures; they never fabricate firsthand production content. Real-provider tests run only through explicitly authorized invocations with scoped secrets, never automatically on PR code.

**Secrets.** Never put credentials in logs, issues, PRs, handoffs or chat. Ordinary PR CI needs no production secrets.

**Fallback.** If a developer's or tester's prompt to the tech lead fails to send, send the same message to the team TPM. If it sent but the work is blocked on an unanswered question, add `blocked` with a comment naming the tech lead and the question, then end the turn; the TPM sees the stall on its next wake.

## The user decides

Material product changes, purchases, credentials, hosting, public launch and every machine-level install. No budget has been fixed, and the absence of a ceiling does not authorize purchases. Only the user starts the lead TPM (`agent/teams/team.py start lead`, never while another live agent owns `lead-tpm`), detects and restarts a silent lead TPM, and may branch in the main checkout when no team is live. The intended VPS is the preproduction environment before launch. Inspect every permission dialog and follow the active approval policy; this document is never permission to answer an approval prompt.

**No machine-level installs without the user's explicit approval.** No agent installs packages, tools or software or changes machine, sandbox or client configuration: `brew`, casks, `pip` or `uv tool`, `npm -g`, system or client settings, Docker images outside the compose file. Project dependencies declared in the repository go through the PR like any other change. When a task truly needs an install, mark the issue `blocked` with the exact command and continue unaffected work; the lead TPM asks the user, quotes the answer in an issue comment, and the agent proceeds only from that link.

**Owner waiver.** When no team is live and the change is owner-driven, the user may skip the independent review. Only on the user's explicit instruction in the session, the user or the lead TPM runs `publish_review.py --owner-waiver "<reason>"` instead of `--record`; it posts a waiver comment on the PR and publishes the status pointing at it. The waiver is the audit trail. Agents never invoke it on their own, and it does not waive CI. A waived change that touches code still gets a Codex review through the ad-hoc channel in the lead TPM's Merge cell; documentation-only changes need none.

## Client constraints

- A Codex sandbox cannot write main's `.git`, so the team TPM runs all main-checkout Git administration; Claude tech leads follow the same flow. The helper and `team.py stop` refuse a caller that cannot write main's `.git`.
- A Codex sandbox writes only under its own worktree root. Codex `never` approval rejects any tool that requires approval, so the generated config sets per-tool approval for the four LSP tools only and leaves the sandbox as the user configured it.
- A Codex reviewer outside a team cannot post to GitHub.
- Claude auto mode may deny a tech lead's `gh pr merge`, a developer killing its own LSP child, copying or writing `.env`, and a pilot posting issue comments. Each is a permission denial.
- `/new`, `/clear` and `cd` inside a running client do not reroot its LSP. A client cannot stop itself through `team.py stop`. `--kind` is optional and must match the role's configured kind.

## Lead TPM

### Always
Coordinate assigned work in [Project 15](https://github.com/users/chenghanlee/projects/15), including child issues, until the user's scope is complete or blocked on the user. Talk only to team TPMs and the user. Read the Project 15 readme (`gh project view 15 --owner chenghanlee`) before picking work; milestones, gates and the dev-adapter policy live there, not in this repository. Track hosting, domain, provider, operator identity, vocabulary and content prerequisites in issues. Tell the user what they need to decide. "Agree, proceed" is final: a change of mind becomes a follow-up issue, never a hold on an authorized merge. Run lifecycle commands under the shared Commands rule. The configured team limit is not a verified cold-start capacity; measure before scaling up.

### Assigned
On each message, read the relevant issue and PR evidence. Pick an unblocked critical-path issue whose prerequisites are integrated and evidenced, preferring the team's current package; package parents are not assignments. One issue is one PR with one outcome. Set `probe` at Ready when the issue delivers evidence only. From the main checkout, in a Herdr terminal, run `agent/teams/team.py start N`, one lifecycle caller per team; it creates or reuses the workspace and four named panes and briefs the team TPM. Send the issue URL to the team TPM. No reservation list or merge slot. When the tech lead's readiness comment proposes a split, create the child issues and re-dispatch. Forward the `Needs from owner:` line to the user and let the team continue without waiting.

### Pushed head
n/a

### Red check
When a team reports red caused by `main`, open an issue for it and tell the user. Nobody repairs it on a task branch.

### Verdict
n/a

### Merge
On a merge report, confirm the issue records the PR, reviewed head, merge SHA and evidence, then retire the team. For an owner-waived code change, arrange the ad-hoc Codex review: give the reviewer its own detached worktree at the reviewed head, create `tmp/review-<issue>/chavruta.md` inside that worktree (ignored by Git) and name the path in the prompt; both sides append rounds until they agree, and the lead TPM posts the outcome on the PR. Nothing under `tmp/` enters the repository. Pilot agents in a disposable team follow the same policy: the tech lead running the pilot posts their evidence.

### Blocked outside the team
Resolve cross-team blockers directly with the team TPMs. For user items, ask the user, quote the answer in an issue comment, and send that link to the team TPM.

### Permission denial
When a tech lead's merge command is denied, the team TPM relays the exact command; run it unchanged from the main checkout, with the same `--match-head-commit`.

### Lost session or environment
After a Herdr restore, confirm `herdr agent list` shows `lead-tpm`; if the name is blank, run `herdr agent rename <pane-id> lead-tpm` before anything else. Never run `team.py start lead` yourself.

### Silence
The user detects a silent lead TPM and restarts it. When a team TPM is silent, inspect Git and pane evidence before reassigning; do not start a second team on the same issue.

### Retire
From a workspace other than the team's, run `agent/teams/team.py stop N`. It verifies client and descendant exit and clean, integrated work, drops only that team's test databases and removes its worktrees and workspace. It refuses dirty or unmerged worktrees, never kills BEAM processes broadly and never deletes the shared engine cache. On failure, read the printed leftovers and do not force-delete them. Do not run overlapping lifecycle calls. Start the team again at its next assignment.

## Team TPM

### Always
Own labels, Project fields, the team start, the tech lead's launch and every worktree provisioning the tech lead requests. Talk only to your tech lead and the lead TPM; talk to the developer or tester only as the fallback in the Silence cell. Run without the Elixir LSP. Read GitHub on every wake; a message is a wake signal, not the record. Run every provisioning command from the main checkout. Post project decisions on the issue. One TPM owns a team's transitions; there is no lock or daemon.

### Assigned
Add `active`. Capture the base SHA and start the tech lead:

```bash
agent/teams/task_worktree.py "$ISSUE-review-team-$N-lead" --team "$N" --role lead [--ui] --pane "$LEAD_PANE" --review-ref "$SHA" --start
```

Use `--ui` for an issue labelled `ui`, and on every later call for that lead; without it the helper resolves the other lead configuration and refuses the running client as a conflict. Take pane IDs from the start output or `herdr pane list`; never guess them. Brief as soon as Herdr reports the client ready, not when compilation finishes: issue URL and base SHA, plus the exact completion command. For each provisioning request from the tech lead (one line: role, pane, exact SHA), run the matching command and reply with pane, absolute worktree and actual SHA:

```bash
agent/teams/task_worktree.py "$TASK" --team "$N" --role dev --pane "$DEV_PANE" --start
agent/teams/task_worktree.py "$ISSUE-review-team-$N-test" --team "$N" --role test --pane "$TEST_PANE" --review-ref "$SHA" --start
```

`TASK` is `<issue>-<slug>`; reuse the existing slug when the title changes. The helper provisions skills and only the chosen client's config, applies the environment in the target pane and starts the real interactive client; repeated calls reuse a matching live session; conflicting assignments fail; inspect config conflicts before replacing generated files with `--force`. Relay the tech lead's `Needs from owner:` line to the lead TPM. Report to the lead TPM only completions and outside blockers.

### Pushed head
On the tech lead's request, advance the tester and the tech lead to the new SHA in place, without `--start`:

```bash
agent/teams/task_worktree.py "$ISSUE-review-team-$N-test" --team "$N" --role test --pane "$TEST_PANE" --review-ref "$SHA"
agent/teams/task_worktree.py "$ISSUE-review-team-$N-lead" --team "$N" --role lead [--ui] --pane "$LEAD_PANE" --review-ref "$SHA"
```

The helper checks reviewer cleanliness even at the same SHA, checks the selected client's configuration before changing HEAD, and moves a running reviewer's clean detached checkout so its LSP keeps the same root. A running tech lead always advances in place; a tester is restarted only through the Lost session cell.

### Red check
n/a

### Verdict
n/a

### Merge
Remove stale labels. Send the lead TPM one line with the PR, reviewed head, merge SHA and evidence link.

### Blocked outside the team
Add `blocked` with the prerequisite, responsible role and next action. Send outside blockers and scope questions to the lead TPM. When the answer arrives, post or link it on the issue and prompt the tech lead.

### Permission denial
Run the main-checkout Git administration a sandboxed tech lead cannot. When the tech lead's recovery needs the user, escalate to the lead TPM with the exact command and error.

### Lost session or environment
Restart or replace the tech lead when its session is lost, at the current head. Provision a fresh tester only for a lost session or a rejected design: `--start` on a running tester at a new SHA stops the old client, verifies descendant exit and launches a fresh one. When an agent's shell lacks the launch environment, re-run the same helper command; it reuses the matching session and reapplies the environment. Inspect Git and pane evidence first; never reset or stash anyone's work.

### Silence
When a developer's or tester's message arrives because the tech lead could not be reached, or an issue carries `blocked` naming an unanswered tech lead question, restart the tech lead. When your completion message to the lead TPM gets no answer, re-send it once on your next wake, then wait.

### Retire
n/a

## Tech lead

### Always
Run the engineering for one issue: decide technical disputes with evidence, brief and dispatch the developer and tester, decide when each is provisioned, and merge. Message the developer and tester freely. Tell the team TPM only provisioning requests and what changes a label, a Project field or a blocker: readiness confirmed, dispatched, PR opened, verdicts, merged, blocked, scope question. Coordinate shared modules directly with other teams' tech leads; tell your TPM only when sequencing, ownership or a blocker changes. Post engineering decisions on the issue or PR before the next step. Escalate material product changes through the TPM.

### Assigned
Confirm pane, worktree and SHA inside the new client (`herdr agent get`, `git -C "$WORKTREE" rev-parse HEAD`). Write the readiness comment on the issue: one outcome, exclusions, exact design sections and real entry points, acceptance scenarios mapped to named tests, runnable verification, available prerequisites, amending the contract when needed. Propose a split when the contract has a second independent outcome or your context would not last to the merge; the lead TPM creates the children. Do not require file ownership lists, reservations or overlap approval; coordinate concrete shared changes when they arise. End with one line, `Needs from owner:` followed by `none` or the secrets, credentials and network access the task requires; nothing else goes on it. Then request the developer (role, pane, SHA) and brief it after confirming its launch: contract link, base SHA, action, owner and the exact completion command. Put outcome and verification in the linked contract, not the brief. The team starts with the work that does not depend on owner items.

### Pushed head
On the developer's first handoff, request the tester at that SHA with `--start`; on later heads, request an advance. After the TPM confirms, send the tester the exact SHA and what changed since its last verdict.

### Red check
A red head is the developer's to repair; the tester does not review it. Red caused by `main` is reported to the TPM as a blocker, never repaired on the task branch.

### Verdict
Findings go back to the developer; repairs get a new tester verdict. A rejected design creates new commits that the tester reviews again. A fresh tester starts only for a lost session or a rejected design. After the tester passes the last repair, go to Merge.

### Merge
Run the sequence in order:

```bash
gh pr update-branch "$PR"   # "already up to date" is not an error
REVIEWED_SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
# Whole-PR review and publish_review.py on REVIEWED_SHA, then:
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks "$PR" --watch
gh pr merge "$PR" --merge --match-head-commit "$REVIEWED_SHA"
```

The branch update comes first so one whole-PR review covers the integrated head. Read the whole diff of that head against `main`. Run the full local check suite exactly once on it, except the `agent/teams` Python checks, which you read from the exact-head `checks` run and link. No second local run and no tester round follow a clean update. Write the `## <short SHA>` round in your comment with these five `###` headings, spelled exactly, each with substance: `Local correctness` (the changed functions and modules), `Downstream effects` (callers, related modules, features and tests), `Whole-project fit` (design, architecture and end-to-end behaviour), `Design challenge` (concrete alternatives, tradeoffs, assumptions), `Defect pass` (a stricter hunt on the integrated diff). Name reviewer and implementer, base and head SHAs, commit verdicts, independently run checks, unresolved findings and follow-ups. Publish the status on that exact head:

```bash
agent/teams/publish_review.py --pr "$PR" --sha "$REVIEWED_SHA" --record "$RECORD_COMMENT_URL"
```

It reads only the round whose heading starts with that SHA and refuses when that round is missing or duplicated, a heading is missing or empty, or the head has moved. The timed `gh pr checks --watch` is the one allowed foreground wait. A timeout, rate limit or failed required check is not success. If the update conflicts, the developer resolves it, the tester reviews the resolution and the sequence restarts. If `main` moves before the merge, the strict gate rejects it: update again, review the base delta, publish a new status. Record the PR, reviewed head, merge SHA and evidence on the issue, then notify the TPM. Do not watch `main` or revert its changes.

### Blocked outside the team
Send scope and product questions, owner prerequisites and install requests to the TPM as one line; the issue gets `blocked` with the exact need. Keep the team on unaffected work.

### Permission denial
Take the worker's report (operation, error, local state) and decide the recovery; you own the next workflow decision, and the worker keeps its checkout until you transfer it. Escalate to the TPM when the recovery needs the user. When your own merge command is denied, send the TPM the exact command; the lead TPM runs it.

### Lost session or environment
If your shell lacks the launch environment, ask the TPM to re-run your helper command rather than recomputing values from config.toml. A worker that lost its session reports through you; request the restart from the TPM with the state from the shared Recovery rule.

### Silence
When the developer or tester does not answer, inspect its worktree and pane before anything else. For a tester, request a fresh session from the TPM. For a developer: Not defined. Post the question on the issue, then prompt the team TPM.

### Retire
n/a

## Developer

### Always
Implement the issue with integration-first TDD under AGENTS.md. Own the branch, worktree and PR; keep one PR comment. Do not switch to another issue before this one merges. For changes under `agent/teams`, run the four checks in [SETUP.md](SETUP.md#check-changes-to-these-scripts) when Ruff and Pyright are already on `PATH`; when they are not, rely on the `checks` run and never install them.

### Assigned
Confirm worktree and SHA. Read the linked contract. Open a draft PR early. Start with the work that does not depend on owner items. Ask the tech lead questions freeform, with a pushed SHA when the question is about code.

### Pushed head
You own green. Before each commit, run `gh pr checks "$PR"` once, without `--watch`, and read the previous push's result; keep working while it runs and push only once that result is in. Never push onto a head whose red you have not repaired. Name any change to check configuration (ignore files, workflow, lint or scanner settings) in your round so the tech lead reviews it explicitly. Add the `## <short SHA>` round and hand off to the tech lead: evidence link, SHA, `action=dispatch tester`, owner.

### Red check
Repair your own red before pushing anything else. Red caused by `main` is reported to the tech lead, not repaired. A tester `RED` round names the failing check.

### Verdict
Repair findings, push, add a round. Answer the tester's questions. A passing verdict needs no acknowledgment.

### Merge
When `gh pr update-branch` conflicts, resolve the conflict and push; the tester reviews the resolution.

### Blocked outside the team
Report the exact need to the tech lead (for an install, the exact command) and continue unaffected work. Never install anything or write secrets into the worktree.

### Permission denial
Follow the shared Recovery rule: preserve the work, report to the tech lead, do not route around the denial.

### Lost session or environment
Check the launch environment with the shared Environment command. If it is missing, report to the tech lead and wait for the helper re-run. Record the shared Recovery state before anything else.

### Silence
Follow the shared Fallback rule.

### Retire
Leave the worktree clean with everything committed and pushed; a dirty or unmerged worktree blocks `team.py stop`.

## Tester

### Always
One session per issue, advanced in place to each reviewed SHA. Keep one PR comment. Review for local correctness first, then callers and related features and tests, then end-to-end behaviour. Trust CI only for commands it ran; independently run missing relevant checks in the assigned environment, except the `agent/teams` Python checks, which come from CI. Your verdict cites code, tests and evidence. For a `probe` issue, pass once.

### Assigned
Confirm worktree and SHA. Review the first pushed head in full and map acceptance scenarios to named tests.

### Pushed head
After the TPM advances your checkout and the tech lead sends the SHA, review the repair delta.

### Red check
A red head is not reviewed. Send one Herdr message to the developer and the tech lead naming the failing check, and add a two-line `## <short SHA> RED` round to your comment.

### Verdict
Add the verdict and evidence as a round. Send its link and the reviewed SHA to the tech lead; send actionable findings to the developer too. Repairs receive another verdict. Apply the shared Findings priorities.

### Merge
Review a conflict resolution when the branch update conflicts. No round follows a clean update.

### Blocked outside the team
When verification needs credentials, network or an install you lack, say so in the round, review everything else and report the exact need to the tech lead.

### Permission denial
Follow the shared Recovery rule.

### Lost session or environment
Report to the tech lead; the TPM provisions a fresh session with `--start`, and you review the current head in full again.

### Silence
Follow the shared Fallback rule.

### Retire
n/a
