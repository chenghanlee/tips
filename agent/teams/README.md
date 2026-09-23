# Agent teams

Operating agreement for the agents that build Tips. Read Events, Shared rules, The user decides, Client constraints, then your role card. [AGENTS.md](../../AGENTS.md) governs engineering. GitHub issues and PRs hold requirements, decisions, review history and evidence. [config.toml](config.toml) defines agent settings; never repeat its defaults in commands or prose. Humans set the machine up once with [SETUP.md](SETUP.md). Run commands from the repository root.

Role names and flags:

| Role | Agent name | Helper flag |
|---|---|---|
| Lead TPM | `lead-tpm` | n/a |
| Team TPM | `team-N-tpm` | n/a |
| Tech lead | `team-N-lead` | `--role lead`, plus `--ui` for the `ui` lead |
| Developer | `team-N-dev` | `--role dev` |
| Tester | `team-N-test` | `--role test` |

## Events

Each card lists these events in order. A message belongs to the event it reports; Assigned covers only the first brief and provisioning requests. `n/a`: the event cannot reach this role. "Not defined": no rule exists; post the question on the issue, then prompt the tech lead (a tech lead prompts its team TPM, a team TPM prompts `lead-tpm`).

1. **Always**: continuous duties.
2. **Assigned**: the first issue, brief or provisioning request arrives; for a reviewer, the first head.
3. **Pushed head**: a later SHA exists on the PR branch.
4. **Red check**: a required check failed on a head. Pending is not red.
5. **Verdict**: a tester or tech lead round is complete.
6. **Merge**: the PR is ready to integrate, or has merged.
7. **Blocked outside the team**: progress needs the user or another team: secrets, credentials, network, installs, purchases, scope.
8. **Permission denial**: a tool or client refused an action.
9. **Lost session or environment**: a client, worktree or launch environment is missing or wrong.
10. **Silence**: a message got no reply, or failed to send.
11. **Retire**: the issue merged and the team's resources are released.

## Shared rules

**Handoff.** For each handoff, record evidence on GitHub, then deliver its link with `herdr agent prompt`. A GitHub comment or a final chat response wakes nobody. Before ending the turn, verify the Herdr command succeeded; if it failed, report the error and do not claim delivery. A handoff is one line: evidence link, SHA, action and owner (the role that acts next); link the existing contract instead of copying it. Every dispatch names the exact recipient and the exact command to run on completion or a blocker; "reply to the lead" alone is insufficient. The same handoff serves readiness, implementation, review, merge and blockers. Provisioning requests and replies, and freeform questions between developer, tester, tech lead and team TPM, are messages, not handoffs; a code question carries a pushed SHA so the reader inspects that revision in its own worktree. A message to two recipients is two prompts. Example; substitute the team number and evidence:

```bash
herdr agent prompt "team-$N-lead" "$EVIDENCE_URL SHA=$SHA; action=dispatch tester; owner=team-$N-lead"
```

**Waiting.** Send via Herdr, finish independent work, then end the turn; the reply arrives as a new prompt. No `sleep`, polling loop, monitor, cron, hook or `--wait`. The one exception is the tech lead's timed CI wait before merge. No status-file PRs, merge queue, polling daemon or own-list approval exists.

**Decisions.** Decision-makers post on the issue or PR before proceeding: tech leads for engineering, team TPMs for project state. Only GitHub records are durable. The asker links that post in its next handoff. The approving review round is the closing record; decisions made in chat that are not already in PR threads go in its body. No separate closing note.

**Commands.** Run lifecycle and messaging commands directly and keep their stdout, stderr and exit status; do not pipe them through `tail` or ad hoc JSON formatters. Parse Herdr JSON only when a later step needs a returned field, under `result`. A formatter failure does not prove failed delivery; inspect once before resending. A successful send confirms submission, not completion.

**Git.** `main` is protected. Work on short-lived `task/<issue>-<slug>` branches in worktrees under `.worktrees/`; keep the slug across title changes. While any team is live the main checkout is read-only for source changes: never switch its branch, edit, commit or run tests there, because running clients and the lifecycle scripts are rooted at it. Repository administration such as fetch and worktree creation runs from main, by the team TPM, or by the lead TPM for `team.py start` and `team.py stop`. The developer owns its task worktree; the tester and tech lead have separate detached, read-only review worktrees; no agent edits another's checkout. Open a draft PR early; mark it ready at the first handoff. Commit cohesive changes and run relevant checks before pushing. Unpushed commits may be reorganized; published commits are fixed, so bring `main` in by merge, never rebase. Never force-push or push implementation to `main`. Repository rules block force pushes on `task/**`, require merge commits, strict up-to-date branches, resolved conversations and the `checks`, `release` and `tips/independent-review` contexts, and delete merged remote heads. That gate is an interlock, not credential isolation. A documentation-only PR needs no local test run; the required CI still runs.

**Issue state.** Add `active` when assigned. Add `blocked` when progress needs outside action, with the prerequisite, responsible role and next action in a comment; a waiting dependency is not automatically a user blocker, and `Needs from owner:` alone does not block. Remove stale labels: `active` and `blocked` after merge. Do not mirror a workflow state machine into Project fields or keep a separate status document. An issue closes only when its required result is integrated and evidenced: partial work uses `Refs #number`, a completing PR uses `Closes #number`. Child issues created during the run count toward the goal. Milestone gates require end-to-end evidence on one integrated revision; closing a package requires its mandatory children and package acceptance evidence. Issues labelled `ui` get the `roles.lead_ui` tech lead, launched with `--ui`; developer and tester settings do not change. Issues labelled `probe` deliver evidence, not a code path: the tester passes once, every review round keeps its five headings at one line each, probe code is disposable, and repairs go no further than the evidence needs.

**One comment per role.** The developer, tester and tech lead each keep one PR comment and edit it in place, adding a `## <short SHA> <outcome>` round per reviewed head, newest last, with `###` headings inside a round. Outcomes: `pushed` (developer), `pass`, `findings` or `RED` (tester), `review` (tech lead). Handoffs link that comment and name the SHA; never create per-round comments.

**Independence.** Nobody reviews or merges their own implementation. The tester may ask the developer anything, but its verdict cites code, tests and evidence, never the developer's explanation, because the common GitHub identity cannot mechanically prove reviewer independence. The tech lead decides technical disputes with evidence. Scope or product questions go tech lead, team TPM, lead TPM, user. Routine technical choices belong to the responsible role. A role receives only duties its configured launch policy can execute.

**Findings.** P0 is critical exposure, irreversible loss or inability to operate. P1 is broken required behaviour, an authorization or consistency defect, or missing evidence needed to integrate safely. P2 and P3 are lower-impact defects or improvements; the tech lead decides whether they block and records follow-up issues when deferred. Do not downgrade findings to pass. Required acceptance failures block completion regardless of severity. After repeated failed repairs, investigate the root cause.

**Recovery.** For a permission blocker, preserve the work and report the failed operation, exact error and local state to the tech lead (a tech lead reports to its TPM); keep working on what the denial does not touch; do not route around the denial through another application or a remote-only commit. For context recovery, keep the issue and branch open and record base and head SHAs, working-tree cleanliness, committed and uncommitted work, unresolved findings, failed or unrun checks and the next action. Transfer ownership explicitly before another writer starts. Never reset or stash someone else's work. Inspect Git and pane evidence before reassigning an unresponsive client; distinguish a working client, a client blocked on a dialog (Permission denial) and a lost one (Lost session).

**Environment.** The helper applies the role's configured model, effort, permissions, database suffix and test port in the live target process, exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV`, `TIPS_CHECK_TIMEOUT_SECONDS` and `TIPS_PROVIDER_ENV_FILE`, and links the main checkout's `.agents/skills` into each worktree. Leave those computed values in place for tests, including Wallaby. Read provider settings from the main checkout's `.env` by path; never write secrets into worktrees. Check with `env | grep -E '^(PGPORT|MIX_ENV|TIPS_)'`; macOS `printenv` prints only its first named variable. Startup reports client launched, not index ready: Expert indexes in the background, and nobody adds a compile gate or a probe LSP; see the [LSP guide](../lsp/README.md). Agents propose defaults and use synthetic fixtures; they never fabricate firsthand production content. Real-provider tests run only through explicitly authorized invocations with scoped secrets, never automatically on PR code.

**Checks.** CI is the evidence for the `agent/teams` Python checks: open the `checks` run for the exact reviewed head, confirm all four steps passed, and link that run in your round. Trust CI only for commands it ran. A leaked secret is a user decision (rotation), never a history rewrite.

**Secrets.** Never put credentials in logs, issues, PRs, handoffs or chat. Ordinary PR CI needs no production secrets.

**Fallback.** Developer or tester: if your prompt to the tech lead fails to send, send the same message to the team TPM. If it sent but your work is blocked on an unanswered question, add `blocked` (the one label a worker may add) with a comment naming the tech lead and the question, then end the turn; the TPM acts on it at its next wake.

## The user decides

Material product changes, purchases, credentials, hosting, public launch and every machine-level install. No budget is fixed; that does not authorize purchases. Only the user starts the lead TPM (`agent/teams/team.py start lead`, never while another live agent owns `lead-tpm`), detects and restarts a silent lead TPM, and rotates a leaked secret. When no team is live, the user or the lead TPM may branch directly in the main checkout and returns it to `main` once the PR merges. The intended VPS is the preproduction environment before launch. Inspect every permission dialog and follow the active approval policy; this document is never permission to answer an approval prompt.

**No machine-level installs without the user's explicit approval.** No agent installs packages, tools or software or changes machine, sandbox or client configuration: `brew`, casks, `pip` or `uv tool`, `npm -g`, system or client settings, Docker images outside the compose file. Project dependencies declared in the repository go through the PR like any other change. When a task truly needs an install, mark the issue `blocked` with the exact command and continue unaffected work; the lead TPM asks the user, quotes the answer in an issue comment, the user runs the install, and the agent proceeds only from that link.

**Owner waiver.** When no team is live and the change is owner-driven (the user asked for it in the session), the user may skip the independent review. Only on the user's explicit instruction, the user or the lead TPM runs `publish_review.py --pr "$PR" --sha "$SHA" --owner-waiver "<reason>"` instead of `--record`; it posts a waiver comment on the PR and publishes the status pointing at it. Agents never invoke it on their own, and it does not waive CI. Before merging a waived change that touches code, complete the ad-hoc Codex review in the lead TPM's Merge cell and post the agreed outcome on the PR; documentation-only changes need none. The lead TPM then merges with the same native command as a tech lead.

## Client constraints

- A Codex sandbox cannot write main's `.git`, so the team TPM runs all main-checkout Git administration; Claude tech leads follow the same flow. The helper and `team.py stop` refuse a caller that cannot write main's `.git`.
- A Codex sandbox writes only under its own worktree root, which is why the chavruta file lives under the reviewer's `tmp/`. Codex `never` approval rejects any tool that requires approval, so the generated config sets per-tool approval for the four LSP tools only and leaves the sandbox as the user configured it.
- A Codex reviewer outside a team cannot post to GitHub.
- Claude auto mode may deny a tech lead's `gh pr merge`, a developer killing its own LSP child, copying or writing `.env`, and a pilot posting issue comments. Each is a permission denial.
- `/new`, `/clear` and `cd` inside a running client do not reroot its LSP. A client cannot stop itself through `team.py stop`. `--kind` is optional and must match the role's configured kind.

## Lead TPM

### Always
Coordinate assigned work in [Project 15](https://github.com/users/chenghanlee/projects/15), including child issues, until the user's scope is complete or blocked on the user. Talk only to team TPMs, the user and an ad-hoc Codex reviewer you launched. Run without the Elixir LSP. Read the Project 15 readme (`gh project view 15 --owner chenghanlee`) before picking work; milestones, gates and the dev-adapter policy live there, not in this repository. Track hosting, domain, provider, operator identity, vocabulary and content prerequisites in issues. Tell the user what they need to decide. "Agree, proceed" is final: a change of mind becomes a follow-up issue, never a hold on an authorized merge. Run lifecycle commands under the shared Commands rule.

### Assigned
Read relevant issue and PR evidence on every message. Pick an unblocked critical-path issue whose prerequisites are integrated and evidenced, preferring the team's current package; package parents are not assignments; discovery may be its own task. One issue is one PR that merges on its own with one outcome; split before Ready, with no numeric cap. Set `probe` at Ready when the issue delivers evidence only. Assign within the configured team limit, one issue per team at a time. From the main checkout, in a Herdr terminal, run `agent/teams/team.py start N`, one lifecycle caller per team, one team at a time; it creates or reuses the workspace and four named panes, briefs the team TPM and prints pane IDs. Dispatch the issue URL to the team TPM with the completion command. No reservation list or merge slot. Create child issues and re-dispatch splits proposed in the tech lead's readiness comment. Forward the `Needs from owner:` line to the user and let the team continue without waiting. The configured team limit is not a verified cold-start capacity; measure before scaling up.

### Pushed head
n/a

### Red check
When a team relays red caused by `main`, open an issue for it, tell the user, and assign it as a task when unblocked. Nobody repairs it on a task branch.

### Verdict
n/a

### Merge
On a merge report, confirm the issue records the PR, reviewed head, merge SHA and evidence, then retire the team. After running a denied merge yourself, record those four items on the issue and tell the team TPM. Ad-hoc Codex review, before merging an owner-waived code change: create a detached worktree at the reviewed head (`git worktree add --detach .worktrees/<issue>-review-codex <sha>`), create `tmp/review-<issue>/chavruta.md` inside it (ignored by Git) naming scope, the review order from AGENTS.md and the reply command `herdr agent prompt lead-tpm "chavruta round N posted: ..."`, split a pane there and start the reviewer with `herdr agent start`. Reviewer and lead TPM append rounds until they agree; a disagreement on a product choice goes to the user. Post the outcome on the PR as one comment linking the rounds. Never commit `tmp/`.

### Blocked outside the team
Resolve cross-team blockers directly with the team TPMs. For user items, ask the user, quote the decision (never a secret value) in an issue comment, and send that link to the team TPM.

### Permission denial
Run denied tech-lead merge commands relayed by the team TPM unchanged from the main checkout, preserving `--match-head-commit`. If the strict gate rejects it, the sequence restarts in the tech lead's Merge cell.

### Lost session or environment
After a Herdr restore, run `herdr agent list`; if your pane has no name, run `herdr agent rename "$HERDR_PANE_ID" lead-tpm` before anything else. Team panes keep their names and worktrees; re-send the last undelivered dispatch to each team TPM. Never run `team.py start lead` yourself.

### Silence
The user detects and restarts a silent lead TPM. When a team TPM is silent, inspect Git and pane evidence before reassigning; never start a second team on the same issue.

### Retire
From a workspace other than the team's, run `agent/teams/team.py stop N`. It verifies client and descendant exit and clean, integrated work, drops only that team's test databases and removes its worktrees and workspace. It refuses dirty or unmerged worktrees; uncertainty or surviving descendants fail the command and preserve the remaining resources; it never kills BEAM processes broadly or deletes the shared engine cache. On failure, inspect the printed leftovers, never force-delete them, and report them to the user: only the owning agent or the user cleans a dirty worktree. Do not run overlapping lifecycle calls. Start the team again at its next assignment.

## Team TPM

### Always
Own labels, Project fields, the team start, the tech lead's launch and every worktree provisioning the tech lead requests. Talk only to your tech lead and the lead TPM, except the developer or tester fallback in Silence. Run without the Elixir LSP. Read GitHub on every wake; a message is a wake signal, not the record. Run every provisioning command from the main checkout. Post project decisions on the issue. One TPM owns a team's transitions; there is no lock or daemon. Report to the lead TPM only your launch readiness, completions and outside blockers.

### Assigned
Add `active`. Fetch, capture the base SHA (`git rev-parse origin/main`) and start the tech lead in the lead pane printed by `team.py start`:

```bash
agent/teams/task_worktree.py "$ISSUE-review-team-$N-lead" --team "$N" --role lead [--ui] --pane "$LEAD_PANE" --review-ref "$SHA" --start
```

Use `--ui` for an issue labelled `ui`, on this and every later call for that lead, including re-runs; without it the helper resolves the other lead configuration and refuses the running client as a conflict, and on a first `--start` it silently launches the wrong lead. Take pane IDs from the start output or `herdr pane list`; never guess them. Once Herdr reports the client ready (`herdr agent get` shows `idle`), brief with the issue URL, base SHA and exact completion command; do not wait for compilation. For each provisioning request from the tech lead (one line: role, pane, exact SHA), run the matching command and reply with pane, absolute worktree and actual SHA:

```bash
agent/teams/task_worktree.py "$TASK" --team "$N" --role dev --pane "$DEV_PANE" --start
agent/teams/task_worktree.py "$ISSUE-review-team-$N-test" --team "$N" --role test --pane "$TEST_PANE" --review-ref "$SHA" --start
```

`TASK` is `<issue>-<slug>`, chosen by the tech lead at readiness and kept across title changes; `SHA` is the exact fetched revision being dispatched. The developer command takes no SHA: the helper creates `task/<TASK>` from `origin/main` or reuses the existing branch. The helper provisions skills and only the chosen client's config, applies the environment in the target pane and starts the real interactive client; repeated calls reuse a matching live session; conflicting assignments fail; inspect config conflicts before replacing generated files with `--force`. Relay the tech lead's `Needs from owner:` line to the lead TPM.

### Pushed head
On the tech lead's request, advance the tester and the tech lead to the new SHA in place, without `--start`:

```bash
agent/teams/task_worktree.py "$ISSUE-review-team-$N-test" --team "$N" --role test --pane "$TEST_PANE" --review-ref "$SHA"
agent/teams/task_worktree.py "$ISSUE-review-team-$N-lead" --team "$N" --role lead [--ui] --pane "$LEAD_PANE" --review-ref "$SHA"
```

The helper checks cleanliness even at the same SHA (build output under `_build/` is ignored; edits are not) and the selected client's configuration before changing HEAD; it advances a clean detached reviewer checkout without changing the LSP root. A running tech lead always advances in place; a tester is restarted only through Lost session.

### Red check
Relay red caused by `main` to the lead TPM as an outside blocker with the failing-check link.

### Verdict
n/a

### Merge
Remove `active` and `blocked`. Send the lead TPM one line with the PR, reviewed head, merge SHA and evidence link. When the lead TPM ran the merge, pass its merge SHA to the tech lead.

### Blocked outside the team
Add `blocked` with the prerequisite, responsible role and next action. Send outside blockers and scope questions to the lead TPM. Post or link answers on the issue, then prompt the tech lead.

### Permission denial
Run the main-checkout Git administration a sandboxed tech lead cannot. Relay a denied merge to the lead TPM as the exact command, including `--match-head-commit`; never run it yourself. Escalate any recovery that needs the user to the lead TPM with the exact command and error.

### Lost session or environment
Environment only (the client runs but its shell lacks the launch variables): re-run the same helper command at the agent's current SHA; it reuses the session and reapplies the environment. Lost session: for the tech lead, re-run its command with `--start` at the current PR head; for the tester, `--start` at the new SHA stops the old client, verifies descendant exit and launches a fresh one, and is also the path for a rejected design. For a lost developer: Not defined. Inspect Git and pane evidence first; never reset or stash anyone's work.

### Silence
When a developer's or tester's message reaches you because the tech lead could not be reached, or an issue carries `blocked` naming an unanswered tech lead question, inspect the lead's pane and worktree per the shared Recovery rule, forward the stuck message, and treat a lost client under Lost session. Restarting a live but silent client: Not defined. When your completion message to the lead TPM gets no answer by your next wake, re-send it once, then wait.

### Retire
n/a

## Tech lead

### Always
Run the engineering for one issue: decide technical disputes with evidence, brief and dispatch the developer and tester, decide when each is provisioned, and merge. Message the developer, tester and team TPM freely. Tell the team TPM provisioning requests and what changes a label, a Project field or a blocker: readiness confirmed, dispatched, PR opened, verdicts, merged, blocked, scope question. Coordinate shared modules directly with other teams' tech leads; tell your TPM only when sequencing, ownership or a blocker changes. Post engineering decisions on the issue or PR before the next step. Escalate material product changes through the TPM. When you run a pilot whose agents cannot post, you post their evidence. On a change to `agent/teams`, review the two `# noqa: S603` calls for trusted executable selection and argument handling; a passing lint does not prove subprocess safety.

### Assigned
Confirm pane, worktree and SHA inside the new client (`herdr agent get`, `git -C "$WORKTREE" rev-parse HEAD`). Write the readiness comment on the issue: one outcome, exclusions, exact design sections and real entry points, acceptance scenarios mapped to named tests, runnable verification, available prerequisites, the task slug, amending the contract when needed. Propose a split when the contract has a second independent outcome or your context would not last to the merge; the lead TPM creates the children. Do not require file ownership lists, reservations or overlap approval; coordinate concrete shared changes when they arise. End with `Needs from owner:` and only `none` or the required secrets, credentials and network access, on one line; it is not a blocker. Then request the developer (role, pane) and, after the TPM confirms, check its pane, worktree and SHA before briefing: contract link, base SHA, action, owner and the exact completion command. Put outcome and verification in the linked contract, not the brief. Start with work independent of owner items.

### Pushed head
Request the tester with `--start` at the first handoff SHA; request advances of the tester and of your own checkout for later heads. After the TPM confirms, check pane, worktree and SHA, then send the tester the exact SHA and what changed since its last verdict.

### Red check
A red head is the developer's to repair; the tester does not review it. Red caused by `main` goes to the TPM as an outside blocker with the failing-check link, never repaired on the task branch.

### Verdict
Findings go back to the developer; you decide whether P2 and P3 block and record deferred ones as follow-up issues. Repairs get a new tester verdict. Design rejection requires new commits and another tester review; a fresh tester starts only for a lost session or a rejected design. After the tester passes the last repair, go to Merge.

### Merge
Run the sequence in order:

```bash
gh pr update-branch "$PR"   # "already up to date" is not an error
REVIEWED_SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
# Request your own advance to REVIEWED_SHA, confirm HEAD, then whole-PR review and publish_review.py:
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks "$PR" --watch
gh pr merge "$PR" --merge --match-head-commit "$REVIEWED_SHA"
```

Update the branch first, request the TPM to advance your checkout to `REVIEWED_SHA`, confirm `git rev-parse HEAD` matches, then review the integrated head's entire diff against `main` once. Run the full local check suite (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test`) exactly once on that checkout, except the `agent/teams` Python checks, which follow the shared Checks rule. No second local run and no tester round follow a clean update. Write the `## <short SHA> review` round in your comment with these five `###` headings, spelled exactly, each with substance (one line each for `probe`): `Local correctness` (the changed functions and modules), `Downstream effects` (callers, related modules, features and tests), `Whole-project fit` (design, architecture and end-to-end behaviour), `Design challenge` (concrete alternatives, tradeoffs, assumptions), `Defect pass` (a stricter hunt on the integrated diff). Name reviewer and implementer, base and head SHAs, commit verdicts, independently run checks, unresolved findings and follow-ups. Publish the status on that exact head:

```bash
agent/teams/publish_review.py --pr "$PR" --sha "$REVIEWED_SHA" --record "$RECORD_COMMENT_URL"
```

It reads only the round whose heading starts with that SHA; it refuses a missing or duplicate round, a missing or empty heading, and a moved head. The timed `gh pr checks --watch` is the one allowed foreground wait. A timeout, rate limit or failed required check is not success. If the update conflicts, the developer resolves it, the tester reviews the resolution and the sequence restarts. If `main` moves before the merge, the strict gate rejects it: update again, review the base delta, publish a new status. Record the PR, reviewed head, merge SHA and evidence on the issue, then notify the TPM. Do not synchronously watch `main` or automatically revert its changes.

### Blocked outside the team
Send scope and product questions, owner prerequisites that stop work, and install requests to the TPM as one line with the exact need; the TPM adds `blocked`. Keep the team on unaffected work.

### Permission denial
Take the worker's report (operation, error, local state) and decide the recovery; you own the next workflow decision, and the worker keeps its checkout until you transfer it. Escalate to the TPM when the recovery needs the user. Send your own denials, including a denied merge, to the TPM as the exact command and error; the lead TPM runs a denied merge and the TPM returns the merge SHA to you.

### Lost session or environment
If your shell lacks the launch environment, ask the TPM to re-run your helper command at your current SHA; never recompute config.toml values. A worker that lost its session reports through you; request the restart from the TPM with the state from the shared Recovery rule.

### Silence
Inspect the silent agent's worktree and pane per the shared Recovery rule. Working: wait. Blocked on a dialog: Permission denial. Lost: Lost session. Live but silent, developer or tester: Not defined. Post the question on the issue, then prompt the team TPM.

### Retire
n/a

## Developer

### Always
Implement the issue with integration-first TDD under AGENTS.md. Own the branch, worktree and PR. Do not switch to another issue before this one merges. Changes under `agent/teams` use only the standard library; their tests use disposable Git repositories, a fake Herdr CLI and owned child processes, never live teams; `# noqa: S603` stays on the two reviewed calls only. Run the four checks in [SETUP.md](SETUP.md#check-changes-to-these-scripts) in your worktree before pushing when Ruff and Pyright are on `PATH`; when they are not, CI runs them and you never install them.

### Assigned
Confirm worktree and SHA. Read the linked contract; push a first commit and open a draft PR early (no handoff yet). Start work independent of owner items. Ask the tech lead freeform questions; include a pushed SHA for code questions.

### Pushed head
You own green. Before each commit, run `gh pr checks "$PR"` once, without `--watch`, and read the previous push's result; keep working while it runs. Never push onto a head whose red you have not repaired; pending is not red. Name any change to check configuration (ignore files, workflow, lint or scanner settings) in your round so the tech lead reviews it explicitly. When the head is ready for review, mark the PR ready, add the `## <short SHA> pushed` round and hand off to the tech lead: evidence link, SHA, `action=dispatch tester`, owner. If the result is still pending, hand off anyway; the tester's read decides.

### Red check
Repair your own red before pushing anything else; a tester `RED` round names the failing check, and the repair round says what changed. Red caused by `main` (the failure reproduces on `main` at your base) is reported to the tech lead, not repaired. A gitleaks hit on a real secret goes to the tech lead for the user's rotation decision.

### Verdict
Repair findings, push, add a round. Answer the tester's questions. A passing verdict needs no acknowledgment. For probes, repair only what the evidence requires.

### Merge
When `gh pr update-branch` conflicts, fetch in your worktree, merge `main` into the branch, resolve, push and hand off; the tester reviews the resolution.

### Blocked outside the team
Report the exact need (install command if applicable) to the tech lead; continue unaffected work. Never install anything or write secrets into the worktree.

### Permission denial
Follow the shared Recovery rule.

### Lost session or environment
Check the launch environment with the shared Environment command. If missing, notify the tech lead and await the helper re-run. Record the shared Recovery state first.

### Silence
Follow the shared Fallback rule.

### Retire
Keep the worktree clean, committed and pushed from the final handoff on; a dirty or unmerged worktree blocks `team.py stop`.

## Tester

### Always
One session per issue, advanced in place to each reviewed SHA. Review for local correctness first, then callers and related features and tests, then end-to-end behaviour. Independently run missing relevant checks in the assigned environment; the `agent/teams` Python checks follow the shared Checks rule. Message the developer and tech lead freely. For a `probe` issue, pass once.

### Assigned
Confirm worktree and SHA. Read `gh pr checks "$PR"` once; a failed required check is Red check, pending is not. Review the first pushed head in full and map acceptance scenarios to named tests.

### Pushed head
After the TPM advances your checkout and the tech lead sends the SHA, read the checks once, then review the delta since your last reviewed head, including any head you refused as red.

### Red check
A red head is not reviewed. Prompt the developer and the tech lead, one message each, naming the failing check, and add a two-line `## <short SHA> RED` round to your comment.

### Verdict
Add the `## <short SHA> pass` or `findings` round with evidence. Send its link and the reviewed SHA to the tech lead; send actionable findings to the developer too. Repairs receive another verdict. Apply the shared Findings priorities; the tech lead decides whether P2 and P3 block.

### Merge
Review a conflict resolution when the branch update conflicts. No round follows a clean update.

### Blocked outside the team
Record missing verification credentials, network access or installs in the round; review everything else and report the exact need to the tech lead.

### Permission denial
Follow the shared Recovery rule.

### Lost session or environment
Environment only: notify the tech lead and await the helper re-run; your session continues. Lost session: the TPM provisions a fresh session with `--start`, and you review the current head in full again.

### Silence
Follow the shared Fallback rule.

### Retire
n/a
