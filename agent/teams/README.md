# Agent teams

Agents building Tips: read this agreement through Client constraints, then your role card. [AGENTS.md](../../AGENTS.md) governs engineering. Keep requirements, decisions, review history and evidence in GitHub issues/PRs. Never repeat [config.toml](config.toml) defaults in commands or prose. Humans perform [SETUP.md](SETUP.md) once. Run commands from the repository root. When changing or reviewing `agent/teams` scripts, also read [the last section](#changing-agentteams-scripts).

Team flow: lead TPM assigns and provisions → tech lead briefs → developer and tester grill with `grill-me` → tech lead releases implementation → developer pushes → tester reviews → tech lead merges → lead TPM retires. Required feedback returns to developer for repair and another tester review. Role cards define gates and exceptions.

| Role card | Agent name | Helper flag |
|---|---|---|
| [Lead TPM](roles/lead-tpm.md) | `lead-tpm` | n/a |
| [Tech lead](roles/tech-lead.md) | `team-N-lead` | `--role lead`, plus `--ui` for the `ui` lead |
| [Developer](roles/developer.md) | `team-N-dev` | `--role dev` |
| [Tester](roles/tester.md) | `team-N-test` | `--role test` |

## Hard limits

**Secrets.** Never put credentials in logs, issues, PRs, handoffs or chat. Ordinary PR CI needs no production secrets. Users decide secret rotation; never rewrite history.

**Installs.** Agents never install packages, tools or software or change machine, sandbox or client configuration: `brew`, casks, `pip`, `uv tool`, `npm -g`, system or client settings, Docker images outside compose. Only the user installs, after explicit approval. Repository-declared dependencies go through PRs. For a necessary install:

1. Tech lead asks lead TPM to add `blocked` with the exact command; team continues unaffected work.
2. Lead TPM asks user and quotes the answer on the issue.
3. User runs the install; agent proceeds only from the quoted-answer link.

**Independence.** Never review or merge your own implementation. Testers may question developers, but the verdict cites code, tests and evidence, never developer explanations, because the shared GitHub identity cannot mechanically prove independence. Tech leads settle technical disputes with evidence. Route scope/product questions through tech lead → lead TPM → user. Responsible roles decide routine technical choices. Assign only duties the role's configured launch policy can execute. With no live teams, only explicit user instruction permits the [owner-waiver procedure](roles/lead-tpm.md#merge); CI remains required.

## Events

Classify messages by the reported event; Assigned covers the first brief, provisioning requests, Brief consensus rounds and release. Later reopening follows Brief consensus from the active event. Each card uses this order. `n/a` means the event cannot reach that role. "Not defined" means no rule exists: post the question on the issue, then prompt the next role up: worker (developer or tester) → tech lead → lead TPM → user.

1. **Always**: continuous duties.
2. **Assigned**: the first issue, brief or provisioning request arrives; includes Brief consensus rounds and release.
3. **Pushed head**: review-ready PR SHA; the tester reads the first head fully, later heads as deltas.
4. **Red check**: required check failed; pending is not red.
5. **Verdict**: tester or tech lead review submitted.
6. **Merge**: PR ready to integrate, or merged.
7. **Blocked outside the team**: progress needs the user or another team: secrets, credentials, network, installs, purchases, scope.
8. **Permission denial**: tool or client refused an action.
9. **Lost session or environment**: client, worktree or launch environment missing or wrong.
10. **Silence**: message unanswered or failed to send.
11. **Retire**: issue merged; team resources released.

## Brief consensus

The tech lead writes each worker's brief to a file and sends a short, single-line explicit `grill-me` invocation through a separate `herdr agent prompt`. Reading the brief is the first step of the session; no separate read-acknowledgment handoff is needed. Use the installed client's skill invocation syntax (`/grill-me` in Claude Code, `$grill-me` in Codex), verified in the setup pilot. Before dispatch, check that `grill-me` and `grilling` folders exist in the main checkout's `.agents/skills/` and `.claude/skills/`, and that `<main-checkout>/tmp/grill/` exists. Missing prerequisites go to lead TPM. These existence checks do not prove client loading or write access; the setup pilot verifies those and round 1 exercises access. If the wrapper or its underlying `grilling` skill is unavailable, report the missing prerequisite through Blocked outside the team; do not silently replace or skip it.

Use one shared Q&A file per worker–tech lead pair: `developer-qa.md` and `tester-qa.md` under `<main-checkout>/tmp/grill/team-N/<issue>/`. The stable `<main-checkout>/tmp/grill/` root gets one user-configured access allowance for all three clients. The tech lead creates the issue directory and provides absolute file paths. It also writes `developer-brief.md` and `tester-brief.md` there; each worker reads its own brief, while only the lead edits brief files. This ignored discussion scratch is the only exception here to main-checkout write isolation; source ownership is unchanged. The first append exercises each participant's access; any denial follows Permission denial, never a fallback path. Each worker appends its numbered questions, recommendations and acknowledgments; the tech lead appends answers. Preserve earlier rounds and take turns writing: save before messaging the other participant. These are discussion scratch files, not workflow status documents.

Send only one short line, with no embedded newline: `/grill-me Read and follow the brief at <absolute brief path>` for Claude Code, or `$grill-me Read and follow the brief at <absolute brief path>` for Codex. Preserve the literal `$` when constructing the shell argument. Do not paste the full brief after the skill command: the pilot showed Claude treating that multiline input as pasted text without invoking the skill.

Fill every placeholder in the corresponding brief file below. Each worker gets its own brief, Q&A path and reply command:

```text
Confirm the grill-me skill and its underlying grilling instructions
actually loaded before round 1. If the invocation arrived as plain text
and loaded no skill, stop and report through Blocked outside the team;
do not substitute ordinary prompt guidance.
Read <contract URL and revision> and your role card.
Confirm your worktree and base SHA <SHA>. Grill the brief with the
tech lead until you share an actionable understanding.

Use <absolute Q&A file path>. Append a numbered round of questions
and recommendations, or acknowledge the revision if you have none.
Notify <tech-lead agent> using <exact Herdr reply command with file
path and round number>, then end your turn.
The tech lead will append answers and message you to read that round.
Read its answers, then append follow-up questions or explicitly
acknowledge the agreed contract revision. Repeat until no blocking
questions remain. To acknowledge: append it to the Q&A file, post an
issue comment with your role/session and the contract revision link,
and send the tech lead that comment link using the supplied reply command.
Interview the tech lead, not the human user.
Look up facts yourself; do not spawn sub-agents for these rounds.
The tech lead's release is the skill's final confirmation for this task;
product and scope decisions still follow the normal user escalation.

Follow Brief consensus in agent/teams/README.md, including root-cause
analysis for disagreements. Preserve earlier rounds; never poll.
Wait for the tech lead's explicit release before implementation.
```

The tech lead reads each notified round, writes its answers, then directly messages that worker with the file path and round to read. Workers do the same for follow-ups and acknowledgment. Verify every message was submitted under shared Commands; follow shared Waiting and Fallback on unanswered or failed messages. Successful delivery is not consensus.

Grill scope, acceptance scenarios, constraints, verification and agreed design decisions. Leave routine implementation choices to the developer. For disagreements about the brief, use 5–10 whys to find the root problem; stop early when two further whys add nothing. The tech lead resolves technical disputes with evidence; product or scope disputes go through lead TPM to the user. Record the reasoning, resolution and any dissent in the contract revision comment. A technical ruling or escalated user decision closes that question; acknowledgment means the worker understands and can act on the decision, not that it prefers it. A concrete remaining acceptance, safety or feasibility blocker after a tech-lead ruling goes to lead TPM, then the user if needed; do not relabel it dissent. When further rounds produce no new evidence or change, decide or escalate rather than repeat the same questions.

The tech lead records resulting decisions in one GitHub contract. Batch settled decisions from both discussions into a linked contract revision comment containing the changes; later changes require a new revision comment. Share that contract revision with both workers, not the other worker's Q&A transcript or implementation explanations. Reopen only affected questions. Each worker appends its acknowledgment to its Q&A file and posts an issue comment naming its role/session and linking the same contract revision as actionable with no unresolved blocking questions. Notify the lead with that comment link. Silence is not agreement. The tech lead releases implementation through shared Handoff, linking the revision and both acknowledgment comments, and tells the tester to await the review head. Zero-question acknowledgment is valid, including for probes and documentation tasks; do not manufacture rounds. Agreement on the contract does not approve the implementation or replace independent review.

Later changes to agreed scope, behavior, acceptance criteria, constraints or design decisions, including invalidated assumptions, require another `grill-me` session in both worker panes for the affected decisions. Ask workers to preserve current work and finish their active turn before sending the new skill invocation. Update each brief file with the new contract revision and affected decisions, then use the same short, single-line invocation. Do not change a brief while its worker is still reading or answering it. Scope the session to the changed decisions; do not restart the whole design tree. Pause affected work, update the same Q&A files and contract, and obtain both acknowledgments before the tech lead releases that work again. Continue unaffected work. Routine implementation and repairs within the agreement do not reopen the gate. Directions after two failed fixes and rejected designs follow this gate if they change the agreement. A replacement worker reads the current contract and completes its `grill-me` session before taking up affected work; reopen the other worker's questions if the contract changes.

## Shared rules

**Environment.** When it launches a client, the helper applies the role’s configured model, effort, permissions, database suffix and test port. A running client keeps that environment and root: rerunning the helper reuses the session and changes neither, so a wrong environment is repaired only by exit and relaunch. The helper exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV`, `TIPS_CHECK_TIMEOUT_SECONDS`, `TIPS_PROVIDER_ENV_FILE`, and links main checkout's `.agents/skills` into each worktree. For Codex roles it also exports `HEX_HOME` as the worktree's ignored `tmp/hex`, because the Codex sandbox cannot write the shared Hex cache. Preserve these values in tests, including Wallaby.

Read provider settings by path from main checkout's `.env`; only the user adds new credentials there. Never write secrets into worktrees. Inspect launch values with `env | grep -E '^(PGPORT|MIX_ENV|TIPS_)'`; macOS `printenv` prints only its first named variable. Provisioning fetches locked dependencies, warms up Dexter and exports `TIPS_DEXTER`, bound to the assigned worktree; Claude and Codex both run it from the shell. Startup is not proof of index freshness. See the [LSP guide](../lsp/README.md). Both clients keep the Credo hook enabled; Dexter gives no compiler diagnostics, so run explicit Mix checks after edits. Agents propose defaults and use synthetic fixtures; never fabricate firsthand production content. Real-provider tests require user-authorized invocations quoted on the issue by lead TPM, with scoped secrets; never run automatically on PR code.

**Handoff.** Every handoff sender:

1. Record evidence on GitHub.
2. Send one line via `herdr agent prompt`: evidence link, SHA, action, owner (next acting role). Link the existing contract instead of copying it. Prompt recipients separately.
3. Before ending the turn, verify the Herdr command succeeded. On failure, report the error; never claim delivery.

GitHub comments and final chat responses wake nobody. Use this handoff for readiness, implementation, review, merge and blockers. Every dispatch must name the exact recipient and completion/blocker command; “reply to the lead” is insufficient. Provisioning requests/replies and freeform questions among developer, tester, tech lead and lead TPM are messages, not handoffs. Code questions must include a pushed SHA for inspection in the recipient's own worktree.

Example: substitute team number and evidence.

```bash
herdr agent prompt "team-$N-lead" "$EVIDENCE_URL SHA=$SHA; action=dispatch tester; owner=team-$N-lead"
```

**Waiting.** After sending via Herdr, finish independent work and end the turn. Replies arrive as new prompts. Never use `sleep`, polling loops, monitors, cron, hooks, `herdr agent prompt --wait` or `herdr agent wait`; only the tech lead's timed pre-merge CI wait is exempt. No status-file PRs, merge queue, polling daemon or own-list approval.

**Decisions.** Before proceeding, tech leads record engineering decisions; lead TPM records project-state decisions. Use an issue or PR: only GitHub records are durable. Askers link the decision in their next handoff. The approving review closes the record; include chat decisions absent from PR threads in its body. No separate closing note.

**Commands.** Run lifecycle and messaging commands directly; retain stdout, stderr and exit status. Never pipe through `tail` or ad hoc JSON formatters. Parse Herdr's JSON output only when a later step needs a field under `result`. After formatter failure, inspect once with `herdr agent get <name>` before resending: failed formatting does not prove failed delivery. Successful sends confirm submission, not completion. Verify checkouts with `pwd` and `git rev-parse HEAD`.

**PR description.** The developer owns the PR title and body, written as a [change description](https://google.github.io/eng-practices/review/developer/cl-descriptions.html): a short imperative title; a body that says what changed and why, plus check-configuration changes and anything CI does not verify. Keep it true until merge. Explain repairs in code and commit messages, not comments.

**Reviews.** Tester and tech lead follow Google's [review comments](https://google.github.io/eng-practices/review/reviewer/comments.html) guide. Submit one review per pass, in one call, on the exact head:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
```

`tmp/review.json`: `{"commit_id": "<head SHA>", "event": "COMMENT", "body": "...", "comments": [{"path": "...", "line": 12, "body": "..."}]}`.

- Inline comments for local issues. The body for general issues and for lines outside the diff, as `path:line`.
- Make required changes clear and give the reason. Mark optional advice `Nit:`, `Optional:` or `FYI:`.
- Approval: line one is `LGTM` alone; line two is your role and session. Add scope or limits only when needed. Any other review starts with your role and session.
- Report what the linked CI run does not establish. Do not repeat the diff, the contract or passing checks.
- Write in plain, simple English. No mannered prose. Succinct and concise. Write like the reader has ADHD.

**Replies.** `agent/teams/pr_review.py list "$PR"` prints the reviews of the last two reviewed heads and every unresolved thread with its IDs and reviewer; `--all` adds earlier heads. Fix the code where that answers a comment. Reply only when useful, to explain a fix, ask or disagree:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/comments/$REPLY_TO/replies" -f body="..."
```

The reviewer who opened a thread resolves it after checking, with `agent/teams/pr_review.py resolve "$THREAD"`. Optional advice may be declined. Feedback in a review body has no thread: its reviewer confirms it in the next review. Handoffs link the review and SHA.

**Git.** Every agent:

- Use short-lived `task/<issue>-<slug>` branches in worktrees under `.worktrees/`; retain slugs across title changes. Never push implementation to protected `main`.
- While any team is live, keep the main checkout read-only for source changes: never switch its branch, edit, commit or test there, because clients and lifecycle scripts are rooted there.
- Leave repository administration (fetch, worktree creation) and `team.py start N` and `team.py stop N` to lead TPM in the main checkout. The helper fetches for reviewer refs and new developer branches, not for a reused developer worktree; whenever freshness matters, request a lead TPM fetch.
- Compare against `origin/main`, never local `main`. Developers own task worktrees; testers and tech leads have separate detached, read-only review worktrees. Never edit another agent's checkout.
- Open draft PRs early; mark ready at first handoff. Commit cohesive changes; run relevant checks before pushing. Reorganize only unpushed commits. Published commits are fixed: merge `origin/main`, never rebase or force-push.

Repository rules block force pushes on `task/**`, require merge commits, strict up-to-date branches, resolved conversations and `checks`, `release`, `tips/independent-review`; merged remote heads are deleted. This gate is an interlock, not credential isolation.

**Issue state.** Lead TPM owns labels; workers may add only Fallback `blocked`.

- Assignment: add `active`.
- Progress needs outside action: add `blocked`; comment with prerequisite, responsible role and next action. A waiting dependency is not automatically a user blocker; a `Needs from owner:` line alone does not block.
- Remove stale labels; clear `active` and `blocked` after merge.
- Track workflow only in Project Status: Backlog, Ready, Active, In review, Blocked, Done. Lead TPM sets them. Never add finer workflow states or a separate status document.
- After launch, escalate scope or role-label changes such as `ui`/`probe` as scope questions. Routine `active` and `blocked` updates remain state changes.
- Close issues only after their required result is integrated and evidenced. Use `Refs #number` for partial work; `Closes #number` for completing PRs. New child issues count toward the goal.
- Milestone gates need end-to-end evidence on one integrated revision. Package closure needs mandatory children and package acceptance evidence.
- Issues labelled `ui` get the `roles.lead_ui` tech lead, launched with `--ui`; developer and tester settings stay unchanged.
- `probe`: deliver evidence, not a code path. Tester reviews once. Probe code is disposable; repair only as evidence requires.

**Required feedback.** Required: critical exposure, irreversible loss, broken required behaviour, authorization or consistency defects, acceptance failures and missing evidence for safe integration. Developers repair required feedback at once and optional advice unless they decline it with a reason. Tech leads settle disputes over what is required and file follow-up issues for deferrals. A failed fix is an attempted fix that fails verification locally, in CI or in review; rerunning a check is not another fix. After two for the same problem, either worker hands off to the tech lead and no third fix is tried before its direction. Preserve work; continue unaffected work.

**Checks.** Trust CI only for commands actually run. If checks are pending, report them as pending without waiting; the tech lead's timed pre-merge wait checks completion. Markdown-only changes run `python3 scripts/check_docs.py`; no Mix run solely for prose. Agent instructions and templates still follow the review policy. CI remains required; waivers require explicit user instruction.

**Recovery.** On permission denial, preserve work. Record operation, exact error and local state in a PR comment (issue if no PR); report to the tech lead, or lead TPM if you are the tech lead. Continue unaffected work. Never bypass denial through another application or remote-only commit.

For context recovery, keep issue and branch open. During Brief consensus, record the shared Q&A paths, latest numbered rounds, contract revision, acknowledgment comment links and whether release occurred; resume unresolved rounds without discarding dissent. Record base and head SHAs, latest review URL, working-tree cleanliness, committed and uncommitted work, unresolved feedback, failed or unrun checks and next action. Reviewers keep scratch output under their worktree's `tmp/` so the checkout stays clean. Explicitly transfer ownership before another writer starts. Never reset or stash another's work. Before reassigning unresponsive clients, inspect Git and pane evidence: working, dialog-blocked (Permission denial), or lost (Lost session or environment).

**Fallback.** Developers and testers: if a tech-lead prompt fails to send, send the same message to lead TPM. If sent but an unanswered question blocks work, add `blocked`, comment with tech lead and question, prompt lead TPM with that comment link, then end the turn.

Any role: if a lead-TPM prompt is rejected, comment on the issue with the undelivered message and exact error, say so in your final response for the user, continue unaffected work and end the turn. The user clears the dialog. Resend once at your next wake if the issue shows no answer to that request.

## The user decides

User decisions: material product changes, purchases, credentials, hosting, public launch, all machine-level installs. No budget is fixed; that does not authorize purchases. Only the user starts lead TPM (`agent/teams/team.py start lead`, never while another live agent owns `lead-tpm`), detects/restarts silent lead TPMs, executes merges denied by lead TPM's client, and rotates leaked secrets. With no live teams, user or lead TPM may branch in the main checkout; return that checkout to `main` after merge. The intended VPS is preproduction before launch. Inspect every permission dialog and follow the active approval policy; this agreement never authorizes answering one.

## Client constraints

- Codex sandboxes cannot write main checkout's `.git`, so lead TPM runs all Git administration there; Claude tech leads follow the same flow. The helper and `team.py stop` reject callers lacking that write access.
- Codex normally writes only within its worktree, so chavruta lives in reviewer's `tmp/`. Brief consensus additionally requires user-configured access to the stable `<main-checkout>/tmp/grill/` root; a prompt or file path grants no access. Codex `never` approval rejects tools needing approval. Codex runs Dexter through the normal shell tool; generated configuration does not bypass approval or sandbox policies. Report any socket or command denial.
- Codex reviewers outside teams cannot post to GitHub.
- Claude auto mode may deny tech-lead `gh pr merge`, developers killing their own LSP children, copying/writing `.env`, or pilots posting issue comments. Treat each as Permission denial.
- `/new`, `/clear` and `cd` do not rebind `TIPS_DEXTER`; it stays bound to the launch worktree. Clients cannot stop themselves with `team.py stop`.

## Changing agent/teams scripts

For `agent/teams` Python changes, CI is the evidence: open the exact-head `checks` run, verify these four steps passed and link the run in your review.

```sh
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

Developers run these before pushing, in their worktree, if Ruff and Pyright are already on `PATH`; otherwise use CI. Agents never install them. Scripts use only standard-library dependencies. Tests use disposable Git repositories, fake Herdr and owned child processes, never live teams. Tests need permission to run `ps` and signal their own children.

Provisioning and client-stop changes also require the real-daemon tests (`-k real_daemons`) with `TIPS_TEST_REAL_DEXTER` and `DEXTER_ELIXIR_LIB_ROOT` set (see the [LSP guide](../lsp/README.md)); CI runs them in the `dexter` job against the freshly built binary. Changes to Codex launch arguments or generated Codex configuration also require the installed-Codex tests with `TIPS_TEST_REAL_CODEX=1`. CI has no Codex client: record the local result in your round.

The reviewed `# noqa: S603` boundaries are `team.py:execute` and `StopAgentTest.client`: variable argument lists, no shell, resolved executable, fixed or test-owned arguments. These are per-call exceptions, not a disabled security rule. Suppress nothing else. When these calls change, tech leads review trusted executable selection and arguments; passing lint cannot prove subprocess safety. Settings: [pyproject.toml](pyproject.toml).
